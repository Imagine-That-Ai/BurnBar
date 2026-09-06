<!--
Copied verbatim into the repo by memory-program D16 / P22, from the design
session's own output. The "Requested return" preamble (a note about that
session's tooling) is the only thing dropped; everything from the H1 below down
to the one local block named at the end of this note is byte-identical to the
source, INCLUDING all TEN amendment blocks. The first is the `##` parent; the
other nine are the `###` blocks nested under it, in source order:

  1. "Amendments from PR1 review (2026-09-05)"        (`##`, the parent block)
  2. "Round 2 (nits) — 2026-09-05"
  3. "Amendments from PR2 review (2026-09-05)"
  4. "Amendments from the PR2 review, round 2 (2026-09-05)"
  5. "Amendments from the PR 1 Cursor security round (2026-09-06)"
  6. "PR2 round 3 rulings (2026-09-06)" — including its "Round 4 (2026-09-06)"
     bold sub-amendment to B8, which is inside block 6 and is not a block of its
     own
  7. "PR3 review rulings (2026-09-05)"
  8. "PR3 round 3 rulings (2026-09-06)"
  9. "PR3 Cursor rulings (2026-09-06)"
 10. "Amendment A1 — the landing partition is not a local project id
     (2026-09-06)" — copied into the repo by PR #2544, which fixed what it rules
     on; it arrives here through `main` and is reproduced unedited

That count is the count of amendment headings in the source, not a carried-over
number: `grep -cE '^#{2,3} (Amendment|Round|PR[0-9])'` over the source returns
exactly 10, and the same grep over this file returns the same 10 lines in the
same order. The header said NINE while block 10 was already in both the source
and `main`, which is the same completeness defect the previous header was
written to close (PR 4 review N1) — it is corrected here rather than carried.

ONE BLOCK IN THIS FILE IS NOT FROM THE SOURCE, and it says so in its own first
sentence:

 11. "D16 Cursor ruling — the link file is a committed, confirmed decision
     (2026-09-06)" — a controller ruling issued on PR #2542 after the source
     session had ended, which directed that it be recorded in this file. It is
     appended at the END, after every copied block, so the byte-identical check
     runs cleanly over blocks 1-10 by stopping at its heading.

     Naming it here rather than letting a reader discover it is the whole point
     of the M2 -> N1 -> N1 lesson: an unannounced local insertion is what makes
     the claim unverifiable. An announced one, placed last, does not.

BYTE-IDENTICAL NOW MEANS BYTE-IDENTICAL. An earlier copy carried one paragraph
that exists nowhere in the source — PR 4's own note about where the Team Fact
badge reads its provenance from. It was removed. A local insertion, however
true, is what makes "byte-identical from the H1 below" unverifiable, and that
was the third recurrence of exactly that defect class (M2 → N1 → N1). A PR's own
notes about its own code live in the PR body and in the code's doc comments,
both of which say more; the controller's record is copied, never edited in
place. The check is one command, and both sides stop at the first `### D16 `
heading because BOTH files now carry local blocks under that prefix — this one
carries block 11, and the source has since gained its own local block ("D16
bootstrap-wiring Cursor ruling"), which belongs to the PR that copies it next
and is deliberately absent here:

    diff <(awk '/^# Team Memory Implementation Design/{f=1}
                /^### D16 /{exit} f' <source>) \
         <(awk '/^# Team Memory Implementation Design/{f=1}
                /^### D16 /{exit} f' <this file>)

Where an amendment contradicts the design text above it, the amendment wins:
that is stated in the amendments themselves and is the rule PR 2, 3 and 4 were
built to.

The design is a LIVING controller record and it is still being amended. Block 9
was appended to the source after PR 4's round-3 review, which found it missing
(N1) exactly as the round-2 review had found block 8 missing (M2) and PR 4's
first docs commit had found block 7 missing. Block 10 landed later still, on
`main`, while this branch was open. All are binding — each says so in its own
opening sentence — so the file is re-copied whole rather than patched, and this
list is enumerated by name so the next copy can be checked instead of trusted. A
block that lands after this commit belongs to whichever PR copies next; the
amendments are ahead of the code by design, and a block being present here is
not a claim that its rulings are implemented on this branch.

Line and file citations are as of `main` @ `80819e891d`; the shipped code has
moved on where the amendments say so.
-->

# Team Memory Implementation Design (D16 / P20–P22)

## 1. Facts established (all citations from `main` @ `80819e891d`, worktree `.claude/worktrees/memprog-team`)

### 1.1 How the personal blind lane seals, uploads and pulls today

| Fact | Citation |
|---|---|
| Doc id = `pensieveSlugHmac("memory-fact:\(identity)", keyData: vaultKey)` — HMAC'd under the **encryption** key | `AgentLens/Services/CloudSync/KnowledgeSyncService.swift:808` |
| AAD is `CloudVaultAADContext(uid:, collection:"memory_facts", docID:, field:"sealedMemory")` | `KnowledgeSyncService.swift:833-838` |
| `sourceRefHmacs` are real, keyed HMACs of `threadLogicalID\|messageID\|contentHash`; `citationCount = min(citations.count, 50)` | `KnowledgeSyncService.swift:840-850`, `:864`, helper at `:955-962` |
| Outer document field set (the shape team facts mirror) | `KnowledgeSyncService.swift:853-867` |
| Upload is **conditional**: read `updatedAt`, skip if the cloud revision is `>=` local (LWW, avoids stale-overwrite) | `KnowledgeSyncService.swift:682-690` |
| Only engine-mirrored (`sourceKind == .agent`) rows carry convergence metadata (`tags/bodyHash/projectID/engineScope`) via `store.memoryCloudFactAttributes` | `KnowledgeSyncService.swift:654-666` |
| Pull rebuilds the AAD, opens the blob, then requires outer `updatedAt` to match the sealed one within 1s or refuses `.updatedAtMismatch` | `MemoryCloudPullService.swift:643-650`, `:660`, `:676-689`, `:740-744` |
| Pull re-derives the expected doc id from the sealed payload and refuses `.identityMismatch` on disagreement | `MemoryCloudPullService.swift:704-716` |
| `.updatedAtMismatch` is **not permanent** → it **freezes the watermark for ever** | `MemoryCloudPullService.swift:168-174` |
| A payload with no engine `projectID` is `unmergeable`, not parked | `MemoryCloudPullService.swift:727-729` |
| Verified rows land in `agent_memory_inbox` via `store.upsertRemoteMemoryFact` | `MemoryCloudPullService.swift:453-460` |

### 1.2 CloudVault crypto — what is reusable verbatim

- `CloudVaultAADContext.init` treats the `uid` slot as a free-form validated part; `validatedPart` bans only control chars and `|` (`OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift:108-116`). **`uid: "team:\(teamId)"` is legal today.** No new AAD primitive is needed.
- Rules-side: `cloudVaultAADContext(userId, collection, docID, field)` at `firestore.rules:1050-1052`, and the generic validator `validCloudVaultAAD` at `:1060-1062` uses `[^|]+` in slot 2, so `team:<teamId>` already passes.
- `validCloudSealedBlob` (`firestore.rules:1098-1135`) governs the **real** envelope shape: `schemaVersion / algorithm / keyVersion / plaintextHMAC / integrityHashVersion / sealedBoxBase64 / createdAt / aad`. **The spec §3.2 example document showing `nonce`/`ciphertext`/`tag` is not the shipped shape and must not be implemented.** Note also `keyVersion <= 100` at `:1113`.
- `sealBlob(_:keyData:keyVersion:aadContext:)` already accepts an explicit `keyVersion` (`CloudVaultCrypto.swift:376-395`). `keyVersion` sits **outside** the AAD and outside the ciphertext; the keyed `plaintextHMAC` is what actually binds the key.
- `pensieveSlugHmac` at `CloudVaultCrypto.swift:803-809`.
- Personal `memory_facts` write rule (the allowlist to mirror): `firestore.rules:3206-3258`. Reads are granted by the consolidated namespace rule at `firestore.rules:1936-1982` — with **no** entitlement check, which is exactly why `MemorySettings.deviceSyncEntitlementSatisfied` exists client-side (`MemorySettings.swift:60-77`).

### 1.3 Key escrow and rotation today

- Escrow public keys live at `users/{uid}/escrow_public_keys/{deviceId}_{keyVersion}`, algorithm `ECIES-P256-AESGCM` (`SessionLogSyncService+VaultKeyPublishing.swift:25-61`).
- `publishCloudVaultKey` enumerates trusted devices, verifies the Signal trust chain (`:99-223`), calls `CloudVaultCrypto.wrapVaultKey(vaultKey, recipientPublicKey:)` (`:280-283`) and writes `cloud_vault_key_wrappers/{deviceId}_{keyVersion}` (`:284-299`).
- `wrapVaultKey` / `unwrapVaultKey`: `CloudVaultCrypto.swift:882-917`.
- **The escrow private key is per-DEVICE**, held in that device's Keychain (`CloudVaultDeviceKeypair(account: "cloud-vault-device:\(context.deviceId)")`, `:229`). The spec's `team_rosters/{teamId}/members/{uid}.escrowPublicKey` — one key per member — **cannot be unwrapped on the member's second Mac.** This is a real gap in the amended spec and §3.2 below fixes it.
- Wrapper rules to mirror (deterministic doc-id composite, trusted-device existence checks, `allow delete: if false`): `firestore.rules:3406-3477`.
- Rewrap worker: `documentRewrapDomains` = registry domains whose `cloudVaultRewrapStrategy` starts with `"document"` (`CloudVaultRotationRewrapWorker.swift:50-52`); the `pensieve` domain carries `memory_facts` (`packages/data-domains/gen/DataDomains.swift:66-76`).
- **Two blockers on "just reuse the rewrap worker":**
  1. `rewrapCollection` is hard-wired to `userRef.collection(collectionID)` and passes `uid:` down (`CloudVaultRotationRewrapWorker.swift:439-491`). It cannot walk `team_memory_facts/{teamId}/facts`. The reusable unit is `CloudVaultCrypto.rewrapCloudVaultDocument(_:uid:collection:docID:…)`, whose `uid` is just an AAD part.
  2. `updatePayload` stamps `updates["updatedAt"] = FieldValue.serverTimestamp()` (`:622`). On a team fact that would make the outer `updatedAt` disagree with the sealed one → `.updatedAtMismatch` → **permanent watermark freeze** for every member. The team rewrap must not write `updatedAt`. *(This is also a latent bug on the personal lane; see §7.)*
  3. `packages/data-domains/gen/DataDomains.swift` is generated — a new domain means editing the generator source, not the `gen/` file.

### 1.4 Cloud Functions: what exists, what does not

- **No multi-user roster or membership construct exists.** The only `teamId` in rules is the single-user pseudo-team `workspaces/{workspaceId}/teams/{teamId}/artifacts`, gated by `callerOwnsWorkspacePath` (`firestore.rules:4953-4966`, helper `:1825-1832`) — intra-account, confirming KD11 as corrected.
- Callable pattern with App Check: `functions/src/callables/escrowDeviceCallables.ts:93-99` and `:363-369` (`enforceAppCheck: getConfig().enforceAppCheck`).
- Invite/redeem with hashed tokens, expiry and public rate limiting: `functions/src/callables/cliLink.ts:30-131`, `functions/src/callables/publicRateLimit.ts`.
- `onCallProduction(name, options, handler)` passes `options` straight through (`functions/src/logging.ts:287-293`) — **it does not enforce App Check on its own.**
- Rules-test harness: `functions/scripts/test-firestore-rules.mjs:38` (`initializeTestEnvironment`), `sealedBlobAt` `:192-197`, `seedBurnBarProMaxEntitlement` `:86`, and the `memory_facts` precedent block T19 at `:5645-5760`. Runner: `functions/package.json:19` → `npm run test:firestore-rules`.

### 1.5 Consent

`MemoryDeviceSyncGate.isEnabled(deviceSyncOptIn, backupOptIn, entitlementSatisfied, remoteConfigEnabled)` (`MemorySettings.swift:501-510`); the levers at `:35-48`, `:50-58`, `:60-77`. `MemoryDeviceSyncScope.current` is the single computation both the sync tick and the Settings toggle must use (`MemoryDeviceSyncInboxGuard.swift:58-103`). The gate snapshot and cycle ordering: `MemoryCloudSyncDomain.swift:148-195`, `:315-366`. The closed-until-resolved RC pattern D17 mirrors: `MemorySettings.swift:257-286`.

### 1.6 Engine convergence identity

- `_convergence_key(project_id, scope, body_hash) = sha256_hex(f"{project_id}|{scope}|{body_hash}")[:32]` — **pipes, not colons** (`tools/openburnbar-mcp/memory_engine/_util.py:71-75`). The spec §4.2 sketch (`"\(teamProjectId):\(scope):\(canonicalBodyHash)"`) does not match and must be corrected.
- Ledger writes/reads: `_sync.py:345-368` (`engine_meta` key `sync_identity:<key>`), `:370-380`.
- `writerDevice` shows the precedent for provenance riding inside the sealed payload → parsed at `_sync.py:534-544` → landed in `meta_json` at `:1210-1219`. **`teamID` follows exactly this route.**
- `agent_memory_inbox` has 7 columns and no kind column (`OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+CommandBoardIndexMigration.swift:77-97`); `entryKind` was added as an optional contract field mirroring a discriminator *inside* `payloadJSON` precisely to avoid a migration (`OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProjectMemoryContracts.swift:486-495`). Same trick for `teamID`.
- Cross-member project identity: `project_identity_fingerprint` uses `origin:<remote.origin.url>` + root commit (`project_code_memory.py:324-341`); `project_id_for_fingerprint` = `"proj_" + sha256("v2:"+fp)[:32]` (`:344-347`); an adoption outranks the fingerprint (`:412-418`).

### 1.7 Constraints (all live gates)

| Gate | Number | Source |
|---|---|---|
| Kernel | `maxFiles: 191, maxLines: 54000` | `scripts/debt/check-core-target-membership-budget.sh:152` |
| Contracts leaf | `maxFiles: 2, maxLines: 1000`; the one file is **943** lines → 57 lines / 1 file headroom | `:144`; `wc -l OpenBurnBarCore/Sources/OpenBurnBarProjectCodeContracts/BurnBarProjectCodeContracts.swift` |
| Untagged `try?` in `AgentLens/Services` | **assert-zero** | `scripts/debt/check-try-optional-budget.sh:19-29` |
| Raw `Firestore.firestore(` | shrink-only from 99 Swift; only `CloudSyncFirestoreGateway.swift` et al. allowlisted | `budgets/raw-firestore-baseline.json` |
| Banned copy | `"zero-knowledge"`, `"zero knowledge"` scanned across `AgentLens/**/*.swift` | `scripts/ci/verify-signal-honesty-copy.sh:52-53`, roots `:140`, exts `:145` |
| New app SQLite table | eight surfaces, same PR | plan `docs/superpowers/plans/2026-09-05-memory-program-revised.md:210-220` |

---

## 2. The seven defects → resolutions

| # | Defect (held attempt) | Resolution | Lands in |
|---|---|---|---|
| 1 | `firestore.rules` team facts `allow create, update` checks only `request.resource.data.uid == request.auth.uid` (branch `firestore.rules:5038-5041`), so any active member overwrites any fact | **Split `create` from `update`.** `create`: `request.resource.data.uid == request.auth.uid`. `update`: `request.resource.data.uid == resource.data.uid && (request.auth.uid == resource.data.uid \|\| isTeamAdmin(teamId))` plus `teamId`/`docID` immutability. Author is immutable even for admins. RED-TEAM-11/12. | PR1 |
| 2 | Doc id HMAC'd under the **current team key**, and `openTeamFact` ignores `keyVersion` (`TeamMemorySyncService.swift:56-59`, `:121-153`) | **Two keys.** A non-rotating `teamSlugKey` derives doc ids; `teamVaultKey_vN` seals content. Pre-image is the engine's convergence identity, not a row id. `openTeamFact` selects the key by `sealedMemory.keyVersion` from a client-held retained-key set; an unheld version is a non-permanent refusal (park, retry after the envelope lands). | PR2 (keys), PR3 (open) |
| 3 | `"a".repeating(64)` placeholder citation HMACs while `citationCount` is real (`TeamMemorySyncService.swift:109-110`) | Reuse `KnowledgeSyncService.sourceRefHmac` verbatim, **keyed under `teamSlugKey`** (not the vault key, so a rotation does not orphan forget-receipt matching), dedup + `prefix(50)`, and `citationCount = sourceRefHmacs.count` — one derivation, not two independent numbers. A rules test asserts the placeholder is rejected. | PR3 |
| 4 | `acceptTeamInvite` never binds the invite to the caller (`functions/src/teamRoster.ts:137-190`): a forwarded token grants full historical read | **Invites are uid-bound at issue.** `inviteTeamMember` resolves the invitee's uid server-side from a verified email via `admin.auth().getUserByEmail`, stores `inviteeUid` + `sha256(token)` (never the token), and `acceptTeamInvite` requires `request.auth.uid === invite.inviteeUid` **and** `request.auth.token.email_verified`. Single-use, 7-day expiry, App Check enforced, rate-limited. RED-TEAM-16. | PR1 |
| 5 | No key source — "out-of-band" | Per-**device** ECIES envelopes at `team_key_envelopes/{teamId}/envelopes/{uid}_{deviceId}_{escrowKeyVersion}_v{teamKeyVersion}`, wrapped by a member/admin client with `CloudVaultCrypto.wrapVaultKey` against that device's published `users/{uid}/escrow_public_keys/{deviceId}_{keyVersion}`. Server writes none. Join issues an envelope for **every retained** team key version before promotion to `active`. | PR2 |
| 6 | No upload path, no UI, a consent gate nothing calls | `TeamMemorySyncDomain` runs after the personal cycle inside `MemoryCloudSyncDomain.sync()` (nested `do/catch`, same shape as the pull half at `MemoryCloudSyncDomain.swift:373-400`), with `TeamMemoryPullService` writing into `agent_memory_inbox`, plus a real Settings section. | PR3, PR4 |
| 7 | "zero-knowledge" wording (`TeamMemorySyncService.swift:7`, `TeamMemoryCopy.swift:19`) — trips a live CI gate | Repo-sanctioned phrasing only: **"blind (the server holds only ciphertext and opaque ids)"**. `scripts/ci/verify-signal-honesty-copy.sh` runs in PR1's command block so the regression cannot land. | PR1 (gate), PR4 (copy) |

---

## 3. The design

### (a) Data model

```
team_rosters/{teamId}                                   ← server-written only
team_rosters/{teamId}/members/{uid}                      ← server-written only
team_rosters/{teamId}/invites/{inviteIdHash}             ← read:false write:false (server-only)
team_rosters/{teamId}/audit_log/{eventId}                ← read: admin; write:false
team_key_envelopes/{teamId}/envelopes/{envelopeId}       ← client-written, self-targeted rules
team_memory_facts/{teamId}/facts/{docID}
team_memory_facts/{teamId}/forget_receipts/{receiptId}
```

**`team_rosters/{teamId}`** adds two fields the spec introduced and the held attempt omitted: `retainedKeyVersions: [1,2,…]` and `slugKeyId` (an opaque `vaultKeyID`-style fingerprint of `teamSlugKey`, so a client can detect it holds the wrong slug key without the server learning the key).

**`team_rosters/{teamId}/members/{uid}`** drops the singular `escrowPublicKey`. Devices are enumerated from the member's own `users/{uid}/escrow_public_keys` — which the roster function reads with Admin SDK at accept time and pins as `escrowDeviceFingerprints: [{deviceId, keyVersion, publicKeyFingerprint}]`. The member document holds fingerprints only, never key bytes, and the wrapping client re-verifies the fingerprint against the fetched public key exactly as `EscrowDeviceSafetyCode.isFingerprint(_:boundTo:)` does at `SessionLogSyncService+VaultKeyPublishing.swift:147`.

**Fact document — field allowlist**, mirroring `firestore.rules:3207-3223` plus three team fields:

```
uid, teamId, docID, schemaVersion, sourceKind, kind, reviewStatus,
sealedMemory, sourceRefHmacs, citationCount,
validFrom, updatedAt, replicatedAt,
teamKeyVersion, rewrapJobId
```

`vaultGeneration` is **excluded** — it is a personal-vault concept and admitting it would let the personal rewrap worker's `updatePayload` shape land here by accident.

**Doc-id derivation (defect 2).** Stable material only:

```swift
// Mirrors memory_engine/_util.py:71-75 EXACTLY — pipes, sha256, 32 hex chars.
let convergenceKey = SHA256("\(teamProjectId)|\(engineScope)|\(bodyHash)").hex.prefix(32)
let slugInput      = "team-memory-fact:\(teamId):\(convergenceKey)"
let docID          = try CloudVaultCrypto.pensieveSlugHmac(slugInput, keyData: teamSlugKey)
```

`teamProjectId` is the checked-in identity from `.openburnbar/project.json` (§6 risk), **not** the device-local engine `projectID`. `teamSlugKey` never rotates: it seals nothing, so a departed member who keeps it learns only which opaque ids exist — which the server already sees. `firestore.rules` binds `validMemoryOpaqueId(docID)` (`:941-947`, the 64-hex shape), unchanged.

**`keyVersion` on every sealed doc.** `sealedMemory.keyVersion == teamKeyVersion == roster.activeKeyVersion` is enforced at write time by rules reading the live roster (spec §3.3, RED-TEAM-13/14). Because `keyVersion` is outside the ciphertext, the *authoritative* binding is the keyed `plaintextHMAC` inside `validCloudSealedBlob`: opening under the wrong key fails, so the label is only a key-selection hint. `validCloudSealedBlob`'s `keyVersion <= 100` cap (`firestore.rules:1113`) is a hard limit on team lifetime rotations — PR2 raises it to 1000 for the team validator only, with a comment naming why.

**Historical-key availability.** The client keeps a `TeamKeyRing` (Keychain, one item per `(teamId, keyVersion)`, account `"team-vault-key:\(teamId):v\(n)"`) populated from every envelope it can unwrap. `openTeamFact` looks up `sealedMemory.keyVersion`; a miss is `.teamKeyVersionUnavailable`, a **non-permanent** refusal that freezes nothing beyond itself and retries once the envelope arrives.

### (b) Key distribution

1. **Creation.** The founding admin's client generates `teamVaultKey_v1` and `teamSlugKey` (`CloudVaultCrypto.generateVaultKey()`, `:312`), stores both in the key ring, wraps both to each of its own trusted devices, and calls `publishTeamKeyEnvelopes` — a *client* write to `team_key_envelopes`, rules-checked, never a callable payload.

2. **Join (spec §6.1.1, kept).** `acceptTeamInvite` sets `status: "pending"`. An active admin client enumerates `roster.retainedKeyVersions`, seals every retained `teamVaultKey_vN` **and** `teamSlugKey` to each of the joiner's escrow device public keys, uploads the envelopes, then calls `promoteTeamMember(teamId, uid, envelopeIds)`; the function verifies an envelope exists for every `(device, retained version)` pair before flipping `status` to `"active"`. **A member is never active-but-blind** — this is what makes Semantic A true rather than aspirational.

3. **Rotation on leave.** `removeTeamMember` → `status: "removed"` + `keyRotationRequired: true` (immediate rules cutoff on read *and* write). An admin client then: generates `teamVaultKey_v(N+1)`, wraps it for remaining active members' devices, runs the team rewrap (below), and calls `rotateTeamKey(teamId, N+1, envelopeIds)` which verifies envelope coverage, appends `N+1` to `retainedKeyVersions`, sets `activeKeyVersion`, and clears `keyRotationRequired`. `rotateTeamKey` is **chunked at 400 writes per batch** — the held attempt's single `db.batch()` (`teamRoster.ts:262-286`) dies at 500 on a large team.

4. **Rewrap.** A new `TeamCloudVaultRewrapWorker` (≈120 lines, `AgentLens/Services/CloudSync/`) that walks `team_memory_facts/{teamId}/facts` through `CloudSyncFirestoreGateway` (never a raw `Firestore.firestore()` — raw-firestore budget) and calls `CloudVaultCrypto.rewrapCloudVaultDocument(data, uid: "team:\(teamId)", collection: "team_memory_facts", docID:, oldKeyData:, newKeyData:, …)`. Its update payload writes **`sealedMemory`, `teamKeyVersion`, `rewrapJobId` and nothing else** — critically **no `updatedAt`**, because `MemoryCloudPullService.swift:687-689` + `:168-174` would otherwise freeze every member's watermark permanently. Registry participation is via a new `team_pensieve` entry in the data-domains **generator source** (not the `gen/` file) so the domain is discoverable and testable the way `documentRewrapDomains` intends (`CloudVaultRotationRewrapWorker.swift:36-52`).

5. **No-retroactive-plaintext statement, stated once and tested:**
   > Rotation protects future writes only. A departed member keeps `teamVaultKey_v1…vN` and every fact already replicated to their device. Rotation makes facts sealed under `v(N+1)` undecryptable to them and the roster cutoff makes the collection unreadable to them; neither retracts bits already sent. `teamSlugKey` is retained by every member who ever held it and therefore **must never seal content** — it names documents, it does not protect them.

### (c) Roster authority

`functions/src/teamRoster.ts` — rewritten, exporting six callables, **all** with `enforceAppCheck: getConfig().enforceAppCheck` (the held attempt passed `{ region }` only, `teamRoster.ts:307`), all wrapped in `onCallProduction`, all appending to `team_rosters/{teamId}/audit_log`:

- `createTeam(name, orgId?)` — requires `hasActiveDataVaultEntitlement` on the caller (checked server-side against the entitlement doc, not trusted from the client).
- `inviteTeamMember(teamId, inviteeEmail, role)` — active-admin only; resolves `inviteeUid` via `admin.auth().getUserByEmail`; stores `{ inviteeUid, tokenHash: sha256(token), role, status, expiresAt }`; returns the token once. **Never stores the token.**
- `acceptTeamInvite(teamId, inviteToken)` — requires `auth.uid === invite.inviteeUid` and `auth.token.email_verified`; single-use; reads the caller's `users/{uid}/escrow_public_keys` with Admin SDK and pins fingerprints; sets `status: "pending"`.
- `promoteTeamMember(teamId, uid, envelopeIds)` — admin-only; verifies envelope coverage; `pending → active`.
- `removeTeamMember(teamId, targetUid)` — admin, or self-leave; `status: "removed"`, `keyRotationRequired: true`.
- `rotateTeamKey(teamId, newKeyVersion, envelopeIds)` — admin-only; strict `activeKeyVersion + 1`; verifies coverage; chunked batches.

`escrowPublicKey` is **removed from the callable surface entirely** — a client-supplied public key is a substitution primitive (a compromised joiner could publish an attacker's key and receive envelopes for it). Keys come only from the member's own rules-protected `escrow_public_keys` namespace.

**Rules.** Roster and invites: `allow write: if false` unconditionally; roster read requires active membership; invites `allow read, write: if false` (the held attempt got this right and it is kept verbatim). Facts: `allow read: if isTeamMember(teamId) && hasActiveDataVaultEntitlement(request.auth.uid)` — the live roster `get()` runs on **every read and every write**, which is what cuts an ex-member off the instant `status` changes rather than at token expiry. Envelopes: `allow read: if isTeamMember(teamId) && resource.data.uid == request.auth.uid` (a member reads only their **own** envelopes — the held attempt let any active member read every member's envelope, harmless today but a needless surface); `allow create: if isTeamMember(teamId) && validTeamKeyEnvelope(...)`, `allow update, delete: if false`.

**Red-team rules tests** (`functions/scripts/test-firestore-rules.mjs`, new block T27):

| Test | Asserts |
|---|---|
| `test_a_non_member_is_denied_read_and_write` | `get`/`list`/`create` all fail with no roster doc |
| `test_an_ex_member_is_denied_after_rotation` | `status: "removed"` → read **and** update both fail |
| `test_a_client_cannot_write_the_roster` | writes to `team_rosters/{t}`, `/members/{uid}`, `/invites/{i}` all fail |
| `test_a_member_of_team_a_cannot_read_team_b` | cross-team read denied |
| `test_a_forwarded_invite_grants_nothing` | a non-invitee with a valid token cannot appear in `/members` (rules) — the uid binding itself is covered by `teamRoster.test.mjs` |
| `test_cross_team_ciphertext_splice_is_rejected` | a `teamA` sealed blob written under `teamB/facts/{id}` fails `validCloudSealedBlob` on the AAD |
| `test_member_cannot_update_another_members_fact` | `resource.data.uid` pin (defect 1) |
| `test_admin_can_update_but_cannot_rewrite_the_author_uid` | admin update succeeds, uid rewrite fails |
| `test_write_under_a_superseded_team_key_version_is_denied` | `teamKeyVersion == activeTeamKeyVersion(teamId)` |
| `test_outer_and_sealed_key_versions_must_match` | `sealedMemory.keyVersion == teamKeyVersion` |
| `test_member_cannot_write_plaintext_fields` | `text`/`body`/`citations`/`embedding` rejected |
| `test_placeholder_citation_hmacs_are_rejected` | `citationCount: 2` with one HMAC fails the count/list agreement check (defect 3) |
| `test_a_member_cannot_read_another_members_key_envelope` | envelope `uid` pin |

### (d) Client

**Consent.** A new per-team lever `teamMemorySyncEnabled: Set<String>` on `MemorySettings` (default **empty** = off for every team), persisted, ANDed with the shipped gate through one pure function beside `MemoryDeviceSyncGate` (`MemorySettings.swift:501-510`):

```swift
enum TeamMemorySyncGate {
    static func isEnabled(
        deviceSyncGateOpen: Bool,       // MemoryDeviceSyncGate.isEnabled(...)
        accountLeversOpen: Bool,        // MemoryDeviceSyncScope.current(...).isOpen
        teamOptIn: Bool,                // this team, default false
        rosterStatusActive: Bool,       // live roster says "active"
        remoteConfigTeamSyncAllowed: Bool,
        remoteConfigResolved: Bool      // closed-until-resolved, per KD12
    ) -> Bool
}
```

Team sync is a strict **subset** of personal sync: turning personal cloud backup off stops team sync too, and a design miss in the team lane cannot strand member data (plan risk #8).

**Upload eligibility.** A local memory qualifies iff *all* hold: `reviewStatus == .approved`; `sourceKind == .agent` (engine-mirrored — a chat memory has no `bodyHash`/`projectID` and therefore no convergence identity, so it can never key a team document, exactly as `MemoryCloudPullService.swift:727-729` reasons for the personal lane); the row's project carries a `teamProjectId` for this team in `.openburnbar/project.json`; the row is not sensitivity-flagged; and the member has opted this team in. Upload is conditional on `updatedAt` exactly as `KnowledgeSyncService.swift:682-690`.

**Pull.** `TeamMemoryPullService` mirrors `MemoryCloudPullService.verify` one-for-one: rebuild the AAD with `uid: "team:\(teamId)"`, `openBlob`, `sameSealedInstant`, allowlist-subset, **re-derive the expected doc id from the sealed payload's `(teamProjectId, engineScope, bodyHash)` under `teamSlugKey`** and refuse `.identityMismatch` on disagreement. Verified rows go into the existing `agent_memory_inbox` via `upsertRemoteMemoryFact`. Team doc ids are HMACs under a different key from personal ones, so the `doc_id` primary key cannot collide.

**Engine provenance — no new table, no migration.** `teamID` and `authorUID` ride **inside** `payloadJSON`, following the `entryKind` precedent (`BurnBarProjectMemoryContracts.swift:486-495`). Engine side:
- `_screen_remote_row` parses `teamID` onto `_RemoteFact.team_id` (the `writerDevice` pattern, `_sync.py:534-544`), rejecting anything not matching a `^team_[a-z0-9]{16}$` token — dropped-but-landed, never a refusal.
- The convergence ledger key is namespaced for team-origin facts: `sync_identity:team:{teamID}:{_convergence_key(...)}`. Personal keys are byte-identical to today, so no existing behaviour moves. A team fact therefore never silently overwrites the member's own private row about the same body.
- `history_meta["teamID"] = fact.team_id` beside `writerDevice` (`_sync.py:1214-1219`), which is what the "Team Fact · contributed by X" badge reads.

**UI.** One new section in `AgentLens/Views/Settings/PrivacyIndexingSettingsView.swift`, beside `MemoryCloudModelsSection`: team list with join/leave, a per-team sync toggle, a **read-only** member list (roster is server-owned), the pending-join state ("waiting for a team admin to share the team keys"), and the honesty footnote. Copy lives in one `TeamMemoryCopy` enum locked by `TeamMemoryCopyGateTests`, in the style of `AgentLensTests/Active/MemoryConsentSheetCopyTests.swift:8-22`.

### (e) Constraints honoured

- **No new app SQLite table.** `teamID` rides in `payloadJSON`; the retained-key ring is Keychain; the team watermark is one more `engine_meta`/`remote_sync_watermarks` row keyed `team:{teamId}`. The eight surfaces (plan `:210-220`) are not opened.
- **Kernel.** Zero new Kernel files. `TeamMemoryFactPayload` lives in `AgentLens/Services/CloudSync/` beside `MemoryCloudFactPayload` (`KnowledgeSyncService.swift:529`), which is app-local. The one contract that must cross the daemon boundary — the optional `teamID` on `BurnBarMemorySyncInboxEntry` — is ~6 lines into the 57 available in `OpenBurnBarProjectCodeContracts` (943/1000).
- **Narrow imports.** `TeamMemorySyncService` imports `Foundation` + `OpenBurnBarCore` only (the held attempt's `import OpenBurnBarKernel` + `OpenBurnBarProjectCodeContracts` is the umbrella-import pattern the budget script polices).
- **`try?` zero.** Every fallible call is `do/catch` with a typed error and an `AppLogger.sync` line, matching `MemoryCloudPullService`'s rejection taxonomy.
- **Raw Firestore zero.** Everything goes through `CloudSyncFirestoreGateway` (`:8-44`), which already supports root collections and nested subcollections.
- **Rules tests** run under `npm run test:firestore-rules` (`functions/package.json:19`) against the emulator.
- **Honesty gate** `scripts/ci/verify-signal-honesty-copy.sh` runs in every PR's command block.

---

## 4. Threat model and the named trust assumption

**In scope.** A curious or compromised **server/operator**: sees ciphertext, opaque 64-hex doc ids, opaque source HMACs, coarse `kind`, timestamps, membership graph, and ECIES-wrapped key envelopes. Never plaintext, embeddings, citations, project names, or any team key. A **non-member**: denied at rules on every read and write. An **ex-member**: cut off at the roster `get()` the instant `status` changes, and cannot decrypt anything sealed under `v(N+1)`. A **forwarded invite**: worthless — the invite is bound to the invitee's uid at issue. A **cross-team splicer**: AES-GCM tag failure, because the AAD carries `team:<teamId>`; and the rules reject the write before that. A **roster-tampering client**: `allow write: if false`, no exceptions, no callable that accepts a membership assertion.

**Explicitly out of scope, and this is the named trust assumption — the one KD11 withdrew the draft's version of:**

> **Every active member of a team holds the team vault key and can therefore read every team fact.** Consent is a display and contribution control, not a confidentiality boundary. A team gate must protect member A from member B — and this design does **not** make that claim, because a shared symmetric key cannot. What it does claim is that *membership itself* is server-enforced and unforgeable by clients, that non-members and ex-members are cut off cryptographically and at the rules simultaneously, and that authorship of a stored fact is immutable even to an admin. A member who runs a modified client can read everything their key opens and can contribute facts their own device fabricated; the audit log records who wrote what, and that is the whole of the protection against a hostile insider.

**Server-side residual metadata (the blindness proof paragraph, to be updated in PR3's body):** team size, join/leave timing, per-member write volume, and the `kind` distribution are visible to the server. Nothing else is.

**The serving boundary, restated after amendment A1 (2026-09-06).** The confidentiality claim on a member's *own* Mac is: a team row is read into a session only where that checkout's committed `.openburnbar/project.json` names the team AND the exact `teamProjectId` the row landed in. That claim is carried by one predicate, `_team_row_servable`, and by nothing else — amendment A1 removed the local project fence from team rows precisely so that no second, weaker filter can be mistaken for the boundary. Widening what a query SELECTS is not a widening of the boundary: the six properties below are each pinned by a test, and forcing the predicate to `True` opens every serving surface at once, which is what makes it the boundary rather than one contributor to it. A1 changes no server-visible metadata, no key handling, no roster authority and no write authority; the named trust assumption above is unchanged.

---

## 5. PR plan (4 PRs, each ≤ ~400 changed lines)

### PR 1 — Roster authority, rules, and the red-team suite
**Files.** `functions/src/teamRoster.ts` (rewritten, ~330 lines), `functions/src/index.ts` (exports), `firestore.rules` (new `team_rosters` / `team_key_envelopes` / `team_memory_facts` blocks, ~110 lines), `functions/scripts/test-firestore-rules.mjs` (block T27), `functions/src/__tests__/teamRoster.test.mjs` (new).
**Tests.** The 13 rules tests in §3(c) plus `test_an_invite_is_bound_to_the_invitee_uid`, `test_an_invite_is_single_use`, `test_an_expired_invite_is_refused`, `test_a_non_admin_cannot_invite_or_remove`, `test_rotate_rejects_a_non_sequential_key_version`, `test_rotate_batches_beyond_five_hundred_writes`, `test_promote_refuses_without_envelope_coverage_for_every_retained_version`.
**Commands.** `npm run test:firestore-rules`; `npm --prefix functions test`; `scripts/ci/verify-signal-honesty-copy.sh`.
**Acceptance.** No client-writable roster path exists anywhere in `firestore.rules`. Every red-team case is green. A forwarded token grants nothing.

### PR 2 — Key distribution, rotation, and rewrap registration
**Files.** `AgentLens/Services/CloudSync/TeamVaultKeyDistribution.swift` (new, ~180 lines), `AgentLens/Services/CloudSync/TeamCloudVaultRewrapWorker.swift` (new, ~120), the data-domains generator source + regenerated `packages/data-domains/gen/DataDomains.swift`, `firestore.rules` (envelope validator, `keyVersion` cap for team blobs), `AgentLensTests/Active/Security/TeamVaultKeyDistributionTests.swift` (new).
**Tests.** `test_a_team_key_is_wrapped_per_device_not_per_member`, `test_a_join_receives_an_envelope_for_every_retained_key_version`, `test_a_departed_member_receives_no_new_envelope`, `test_the_slug_key_survives_a_rotation`, `test_rewrap_reseals_in_place_and_does_not_change_the_doc_id`, **`test_rewrap_does_not_touch_the_outer_updated_at`** (the watermark-freeze guard), `test_the_team_rewrap_domain_is_discoverable_from_the_registry`.
**Commands.** app test target; `scripts/debt/check-core-target-membership-budget.sh`; `scripts/debt/check-raw-firestore-budget.sh`; `scripts/debt/check-try-optional-budget.sh`.
**Acceptance.** A rotation re-seals every live team fact under the same doc id and leaves `updatedAt` untouched; a joiner can open a pre-rotation fact.

### PR 3 — Client sealer, pull, consent, engine provenance
**Files.** `AgentLens/Services/CloudSync/TeamMemorySyncService.swift` (rewritten), `TeamMemoryPullService.swift` (new), `TeamMemorySyncDomain.swift` (new), `MemoryCloudSyncDomain.swift` (nested team half), `MemorySettings.swift` (`TeamMemorySyncGate` + lever), `OpenBurnBarProjectCodeContracts/BurnBarProjectCodeContracts.swift` (+`teamID` on the inbox entry, ~6 lines), `tools/openburnbar-mcp/memory_engine/_sync.py` (parse `team_id`, namespace the ledger key, `history_meta["teamID"]`), `AgentLensTests/Active/TeamMemorySyncTests.swift`, `tools/openburnbar-mcp/tests/test_memory_blind_sync.py`.
**Tests.** `test_a_team_fact_seals_and_opens_under_the_team_key`; `test_the_aad_binds_the_team_id`; `test_the_doc_id_is_stable_across_a_key_rotation`; `test_two_members_who_learn_the_same_fact_derive_the_same_doc_id`; `test_citation_hmacs_are_real_and_the_count_matches_the_list`; `test_opening_selects_the_key_by_key_version`; `test_an_unheld_key_version_parks_and_does_not_freeze_the_cursor`; `test_team_sync_failing_closed_does_not_affect_member_sync`; `test_a_chat_memory_never_qualifies_for_team_upload`; `test_the_swift_convergence_key_matches_the_python_one` (golden vector against `_util.py:71-75`, asserted in **both** languages); Python: `test_a_team_fact_does_not_converge_with_a_personal_row`, `test_team_provenance_lands_in_meta_json`.
**Commands.** app test target; `python -m pytest tools/openburnbar-mcp/tests`; the three debt gates.
**Acceptance.** A fact uploaded by member A is opened, merged and attributed on member B's engine; team sync failing closed leaves personal sync green; the blindness proof paragraph is updated in this PR body.

### PR 4 — UI, copy, docs
**Files.** `AgentLens/Views/Settings/TeamMemorySection.swift` (new), `PrivacyIndexingSettingsView.swift` (wiring), `AgentLens/Views/Memory/TeamMemoryCopy.swift` (rewritten), `AgentLensTests/Active/TeamMemoryCopyGateTests.swift` (new), `docs/` blindness-proof + security page updates.
**Tests.** `test_team_join_dialog_displays_semantic_a_historical_access_copy`; `test_team_leave_dialog_displays_semantic_b_future_protection_only_copy`; `test_team_settings_footnote_contains_both_invariants`; `test_no_team_copy_string_contains_a_banned_over_claim` (in-process mirror of the CI gate's banned list).
**Commands.** app test target; `scripts/ci/verify-signal-honesty-copy.sh`.
**Acceptance.** Both semantics appear verbatim in shipped UI; the honesty gate is green with no new allowlist entries.

---

## 6. Reuse from the held attempt

**Keep verbatim.**
- `TeamMemorySyncService.teamAADContext` (`:45-52`) — `uid: "team:\(teamID)"` through the existing `CloudVaultAADContext` is exactly right and needs no new primitive.
- The roster/invite/envelope **read** rules and the unconditional `allow write: if false` on `team_rosters` and `/invites` (branch `firestore.rules:4971-5001`).
- The `validTeamMemoryFactKeys` allowlist (branch `:5015-5033`) — minus nothing, plus nothing.
- The anti-leakage negations, kind/sourceKind enums, `citationCount` bounds, timestamp checks, and `validCloudSealedBlob` call with the team AAD (branch `:5045-5060`).
- The `allow delete` rule (branch `:5071-5072`) — it already had the ownership pin the create/update rule lacked.
- `TeamRosterService.assertActiveAdmin` (`teamRoster.ts:290-300`) and the `newKeyVersion === activeKeyVersion + 1` monotonicity check (`:248-253`).
- `TeamMemoryCopy.joinSemanticA` / `.leaveSemanticB` / `.alertTitle` / `.alertDestructiveAction` / `.teamFactBadgeLabel` — the semantics are right; only `settingsFootnote` is wrong.
- Test names `test_a_team_fact_seals_and_opens_under_the_team_key`, `test_the_aad_binds_the_team_id`, `test_team_sync_failing_closed_does_not_affect_member_sync`, `test_the_ui_states_both_join_and_leave_semantics` (P22's contract).

**Rewrite.**
- `deriveDocID` (`:56-59`) — wrong key, wrong pre-image.
- `sealTeamFact`'s `sourceRefHmacs` and the `String.repeating` helper (`:109`, `:156-160`) — delete both.
- `openTeamFact` (`:121-153`) — must select the key by `sealedMemory.keyVersion` and re-derive the expected doc id.
- `isTeamSyncAllowed` (`:64-73`) — replace with `TeamMemorySyncGate`, ANDed with the shipped four-lever gate and the live roster status.
- `TeamRosterService.acceptInvite` (`:137-190`) — no caller binding; rewrite around `inviteeUid` + `email_verified` + token hashing.
- `inviteMember` (`:102-132`) — stores the raw token; must store `sha256(token)` and resolve `inviteeUid`.
- `rotateTeamKey` (`:233-288`) — single unbounded batch; no `retainedKeyVersions`.
- All five callable wrappers (`:305-388`) — no `enforceAppCheck`, no rate limiting, no audit log, no entitlement check.
- The `escrowPublicKey` parameter everywhere — client-supplied public keys are a substitution primitive; read them from `users/{uid}/escrow_public_keys` server-side instead.
- The branch's `allow create, update` fact rule (`:5038-5069`) — split, pin `resource.data.uid`, add the live `activeTeamKeyVersion` binding.
- `TeamMemoryCopy.settingsFootnote` (`:19`) and the `TeamMemorySyncService` doc comment (`:7`) — "zero-knowledge" fails `scripts/ci/verify-signal-honesty-copy.sh`.

---

### Critical Files for Implementation
- `/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar/.claude/worktrees/memprog-team/firestore.rules`
- `/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar/.claude/worktrees/memprog-team/AgentLens/Services/CloudSync/KnowledgeSyncService.swift`
- `/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar/.claude/worktrees/memprog-team/AgentLens/Services/CloudSync/MemoryCloudPullService.swift`
- `/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar/.claude/worktrees/memprog-team/AgentLens/Services/CloudSync/SessionLogSyncService+VaultKeyPublishing.swift`
- `/Volumes/Samsung NVME/offloaded-home/Documents/Projects/BurnBar/.claude/worktrees/memprog-team/functions/scripts/test-firestore-rules.mjs`
---

## Amendments from PR1 review (2026-09-05)

Four controller rulings issued after the adversarial security review of PR 1
(`/private/tmp/claude-502/memprog/team-pr1-review.md`, REQUEST_CHANGES, 11
CONFIRMED findings). These **amend §3(a)–(c)** and are binding on PR 2–PR 4.
Where a ruling contradicts the design text above, the ruling wins.

**F1 — envelope `create` is no longer open to every active member.**
§3(c)'s `allow create: if isTeamMember(teamId) && validTeamKeyEnvelope(...)`
(design line ~174) was a permanent denial-of-key primitive: envelopes are
create-only and immutable, so any member could squat a joiner's whole id set —
including the `_slug` slot — with garbage wraps, and nobody could ever repair
them. The rule is now:

```
allow create: if (isTeamAdmin(teamId) || (isTeamMember(teamId) && request.resource.data.uid == request.auth.uid))
  && validTeamKeyEnvelope();
allow update, delete: if false;
```

Every envelope carries `wrappedBy`, pinned by the rules to `request.auth.uid`,
and the recipient `d.uid` must exist on the roster. `promoteTeamMember` /
`rotateTeamKey` coverage **counts only envelopes whose `wrappedBy` is an active
admin, or the recipient themself**. Self-wrap is the legitimate member case: a
founder bootstrapping their own key material, and a member enrolling a second
Mac.

**F2 — coverage verification must bind the pinned fingerprint.**
`escrowDeviceFingerprints` existed but no layer read it back, so the
anti-substitution defence §3(c) claims ("a client-supplied public key is a
substitution primitive", so keys come only from the member's own namespace) was
decorative. Coverage now requires, for every pinned
`(deviceId, escrowKeyVersion, publicKeyFingerprint)` × every retained key
version (plus the slug key), an envelope whose `deviceId`, `escrowKeyVersion`,
`keySlot` and `recipientPublicKeyFingerprint` all match. An envelope for an
unpinned fingerprint is **ignored, not counted** — it covers nothing. The rules
keep only the shape check (64 hex); the semantic binding lives in the function.

**F3 — the founder is pinned like everyone else.**
`createTeam` reads the founder's `users/{uid}/escrow_public_keys` ∩ trusted
`escrow_devices` and pins fingerprints exactly as `acceptTeamInvite` does, and
requires at least one trusted device (founding a team from an unenrolled machine
is refused). The "a member with no pinned device contributes no requirement"
skip is **deleted**: `rotateTeamKey` refuses outright while any active member has
zero pinned devices. The founder is subject to the same coverage rule as every
joiner, and receives their own envelopes by self-wrap (F1).

**F4 — `acceptTeamInvite` must never demote.**
It reads `team_rosters/{teamId}/members/{uid}` first. `active`, `pending` or
`suspended` → refuse `already-exists` and **do not touch the row**. `removed` →
re-join as `pending` (a fresh invite is still required; the invite is still
burned single-use). No member row is ever written with `merge: false` over an
existing row; the re-join merges and deletes `removedAt`. Without this, a stale
second invite could demote the last active admin to `{pending, member}` and
freeze the tenant permanently, walking around the last-admin guard with no
removal taking place.

**Also settled, for PR 2–4 authors:**

- **Forget receipts are claims, not authority.** `memoryIdHmac` and
  `sourceRefHmacs` on `team_memory_facts/{teamId}/forget_receipts` are
  deliberately unbound — the rules cannot tell whose fact an opaque HMAC names.
  PR 3's pull path must treat a receipt as "`uid` asks to forget X" and honour it
  only where `uid` already has authority to delete X. The fact-level
  `allow delete` is the real boundary.
- **Fact `delete` is deliberately not entitlement-gated** while `read`/`create`/
  `update` are. A lapsed subscription must not trap a user's data. Membership is
  still required.
- **Plaintext denial has exactly one enforcement point:** `keys().hasOnly(...)`.
  The redundant `!("text" in d)` negations were mutation-tested, found dead, and
  deleted. Do not re-add them; add a test instead.
- **Rules size is a blocking prerequisite for PR 2.** Shipped size after PR 1 is
  150,998 B against a 153,600 B fail line — **2,602 B of headroom**. PR 2's own
  scope (envelope-validator refinement + raising the team `keyVersion` cap) will
  not fit. PR 2 must land a compaction of an existing block in the same PR. PR 1
  already spent its compaction budget (shared `validMemoryFactKind` and
  `readsTeamMemory` helpers, `let d =` bindings, no new AAD helper, dead
  negations removed).
- **`rotateTeamKey` is not atomic across its two commits**, deliberately. The
  team document is the sole authority for `activeKeyVersion`, so a mid-rotation
  failure leaves writes pinned to `N`, `keyRotationRequired` true, and an
  idempotent retry. Any PR 2 change to the rotation write path must preserve
  that ordering (member rows first, team document last).

### Round 2 (nits) — 2026-09-05

Six non-blocking findings from the re-review
(`/private/tmp/claude-502/memprog/team-pr1-review-r2.md`, APPROVE_WITH_NITS) and
the F10 residual, all fixed in PR 1. These further amend §3(a)–(c).

**N-2 — coverage does NOT require the wrapper to be currently active. (Controller
ruling.)** The F1 amendment above said coverage "counts only envelopes whose
`wrappedBy` is an active admin, or the recipient themself". That is amended:
an envelope counts iff `wrappedBy` is the recipient, **or** `wrappedBy` has a
member row on this team with `role == "admin"` **in any status**.

The reasoning, which PR 2–4 authors must not undo: the Firestore rules already
enforce, at envelope-CREATE time, that the writer was an active admin or the
recipient. **That write-time rule is the authority.** Re-testing it at read time
buys no security — a wrap that exists was authorised when it was made — and
costs availability, because envelopes are create-only and immutable. If the
admin who wrapped a pending joiner's envelopes leaves before the promotion
lands, a "currently active" test strands that joiner permanently: the wraps are
perfectly decryptable, and no surviving admin can repair them, because `create`
is denied on documents that already exist. A departed admin's pre-departure
wraps therefore stay valid. **Rotation is what revokes a departed admin's key**,
not coverage arithmetic — which is exactly what `removeTeamMember` sets
`keyRotationRequired: true` for. Proved by
`test_a_departed_admins_wrap_still_covers_a_pending_joiner`.

**N-3 — the accept guard is transactional.** `acceptTeamInvite`'s live-member-row
read and its member-row write now live **inside** the same transaction that
burns the invite. Two concurrent accepts of two different live invites for the
same uid previously both cleared the guard and both wrote the row (last write
won the role). One row write, one `already-exists`, and the loser's invite is
left unburned.

**N-4 — promote/rotate re-read the key state they decided against.**
`promoteTeamMember` and `rotateTeamKey` compute an envelope requirement set from
`activeKeyVersion` / `retainedKeyVersions`, verify coverage with a read fan-out,
and only then write. Both now commit through a transaction that re-reads the
team document and throws `aborted` if that key state moved, so a rotation
landing inside the window cannot promote a member into blindness for v(N+1).
The rotation's member-row chunks stay outside the transaction: that ordering is
the F5 recovery contract and must be preserved.

**N-5 — an unpinnable escrow key version is skipped, not pinned.**
`pinEscrowDeviceFingerprints` requires `Number.isInteger(keyVersion) &&
keyVersion >= 1`, matching the rules' `d.escrowKeyVersion is int && >= 1`.
Devices failing it are skipped and logged
(`team_roster.escrow_key_version_unpinnable`); a member with no pinnable device
falls through to the existing "publish and trust at least one device" refusal.
Pinning such a version demanded an envelope that could never be written, making
the member permanently unpromotable.

**N-1 — the `keySlot` regex is deleted**, by exactly the argument that deleted
the plaintext negations: the envelope-id pin forces `keySlot` to be the id's
tail, and the roster authority binds it to `requirement.keySlot` server side.
Mutation-tested dead. Shipped rules size is now **150,948 B** against the
153,600 B fail line — **2,652 B of headroom**. The PR-2 blocker in the round-1
amendment stands unchanged: PR 2 must land a compaction in the same PR.

**F10 / N-6 — the BOLA proof reaches the clause it is named for.**
`generate-bola-victim-seeds.mjs` seeds a real pending invite bound to Bob whose
document id is `sha256(the token the attacker presents)`, so `acceptTeamInvite`'s
cross-tenant proof is refused by the `inviteeUid !== callerUid` comparison rather
than by "no such invite". Keep `PROBE.inviteToken` in that generator in sync with
the literal in `teamRoster.bola.test.ts`.

### Amendments from PR2 review (2026-09-05)

Controller rulings issued after the adversarial review of PR 2
(`/private/tmp/claude-502/memprog/team-pr2-review.md`, REQUEST_CHANGES: B1, B2,
B3 blocking). These **amend §3(a)–(b)** and are binding on PR 3–PR 4. Where a
ruling contradicts the design text above, the ruling wins.

**B1 — key distribution is idempotent by construction, not by assertion.**
§3(b)1–3 said "an idempotent retry" without saying what makes it one. Two
mechanisms are now required and shipped:

*(a) Envelope writes are read-before-write.* `firestore.rules` says
`allow update, delete: if false` on `team_key_envelopes`, and Firestore
classifies `setData(merge: false)` over an existing document as an UPDATE — so a
blind re-publication is DENIED, not overwritten, and a retry dies on the first id
a previous attempt already wrote. Every publication therefore fetches the id
first: an envelope already addressed to the same
`(uid, deviceId, escrowKeyVersion, keySlot, recipientPublicKeyFingerprint)` is
counted toward coverage and skipped; a mismatch raises. An update is never
attempted.

*(b) A generation is minted exactly once.* `v(N+1)` (and `v1` / `teamSlugKey` at
bootstrap, and a joiner's wraps) is persisted in `TeamKeyRing` as a **pending**
entry keyed `(teamId, slot)` BEFORE any network write, reused verbatim by every
retry, and promoted pending→active only after `rotateTeamKey` succeeds.
Regenerating it strands the members who already hold envelopes, permanently,
because a second key's envelopes could never replace the first's immutable
documents. The ring protocol therefore carries `pendingKey` / `storePending` /
`promotePendingKey`, and PR 3's `openTeamFact` must read the ACTIVE slot first
so a stale pending entry can never shadow a published generation.

**B2 — the rewrap converges from ANY retained generation.** §3(b)4 assumed
"old key → new key". Two ordinary interruptions spread a corpus over three
generations, and a worker that assumed one step back aborts on the first fact it
cannot open — after the callable has already recorded the new version, leaving
those facts un-rewrappable and (because the rules pin writes to the active
version) unwritable for ever. The worker takes the key ring and selects the
opening key per document from that document's own `sealedMemory.keyVersion`. A
generation the ring does not hold, or a blob that will not open under the key it
names, is COUNTED and skipped; the pass completes over the rest and reports the
count. It never throws on a single document.

**N1 — rotation completeness is recorded.** `rotateTeamKey` clears
`keyRotationRequired` and advances `activeKeyVersion` before a single fact is
re-sealed — it must, because the rules pin fact writes to the roster's active
generation — so the roster alone cannot distinguish "re-keyed" from "never ran".
A pass with zero skipped documents records `(jobId, teamKeyVersion)`. **PR 2 uses
a LOCAL note** (`UserDefaults`), because no server field exists:
`team_rosters/**` is `allow write: if false` and neither `promoteTeamMember` nor
`rotateTeamKey` accepts a marker. **PR 4 must promote it to a roster field
written by `rotateTeamKey`**, so every member sees it rather than only the admin
who happened to run the pass, and must surface `skippedDocuments`
("re-sealing 812 of 4,010") rather than dropping it.

**Concern 4 — the `team_pensieve` registry entry ships with the UI, in PR 4.**
The data-domain registry is not a private index: every entry renders
unconditionally as public trust copy on `burnbar.ai/privacy`
(`privacy.astro` + `ClaimsLedger.astro`), in the Android privacy labels and in
the macOS Control Center, and `validateRegistry` supports no `status` /
`visibility` / `unreleased` field that could hide one (`entitlementGate` renders
a domain as *locked*, not absent). Landing the row in PR 2 would publish a 90-word
"Team Memory" entry describing a shared-tenant feature no user can create for two
more PRs. The entry, its regenerated `gen/*` artifacts, the Android copy, the
website trust module, the `dataExport` / `dataDeletion` / `dataDomainUsage`
classifications and the discoverability test therefore move to **PR 4**. Nothing
in the team lane may depend on registry discovery: the team rewrap worker is
invoked DIRECTLY by the rotation flow, unlike the personal lane, which is
data-driven over `documentRewrapDomains`. When the entry does land its
`firestorePaths` must stay EMPTY — that field means "per-user subcollection" to
every consumer, and both the macOS and iOS personal rewrap workers iterate it as
`userRef.collection(id)`.

**Also settled, for PR 3–4 authors:**

- **`schemaVersion == 2` is repeated in all three sealed-payload validators, on
  purpose.** `scripts/privacy/scan-chat-cloud-plaintext.mjs` asserts statically
  that the text of `validCloudSealedPayload` pins it; factoring the clause into a
  shared shape silently defeated that gate. Held per-caller it is also
  mutation-killable in each, which a redundant copy would not be. Do not
  "de-duplicate" it again. `test_a_sealed_payload_above_schema_version_2_is_rejected`
  is the behavioural cover.
- **The client mirrors the envelope-create rule on unwrap.** A successful ECIES
  open proves only that the wrap was made for this device's escrow key. The ring
  additionally requires `recipientPublicKeyFingerprint` to be one this device's
  own roster row pins at the escrow generation the envelope names, and
  `wrappedBy` to be this account or a uid holding an `admin` member row **in any
  status** (PR 1 amendment N-2 — a departed admin's pre-departure wraps stay
  valid). Ties resolve to the highest escrow generation, deterministically.
- **INFO-4 carried forward: PR 3 owns the testable half of the
  no-retroactive-plaintext statement.** "`teamSlugKey` must never seal content"
  has no assertion in PR 2 because nothing seals yet. PR 3 must add one — an
  explicit test that the slug key is used only for `pensieveSlugHmac` and never
  reaches `sealBlob` / `sealPayload` — not an assumption.
- **The Keychain ring's account literal is
  `vault-key:<teamId>#<slot>`** inside service `com.openburnbar.team-vault-key`,
  with pending entries at `vault-key:pending#<teamId>#<slot>`. `#` cannot occur
  in a team id (`team_<hex>`) or a slot (`v<N>` / `slug`), so the composite is
  unambiguous by construction. This supersedes the design's
  `"team-vault-key:\(teamId):v\(n)"`.
- **Follow-up, not a blocker:** `validRoamingProfileSealedPayload`'s
  `matchesCurrentVaultKey` clause is untested (mutating it away kills no rules
  test). Pre-existing, byte-identical before and after PR 2's compaction. Owed: a
  roaming-profile stale-`vaultKeyID` denial test.

### Amendments from the PR2 review, round 2 (2026-09-05)

Controller rulings issued after the scoped re-review of PR 2
(`/private/tmp/claude-502/memprog/team-pr2-review-r2.md`, REQUEST_CHANGES: one
new HIGH, **B4**, plus two flags). These **amend the B1 ruling above** and are
binding on PR 3–PR 4.

**B4 — a rotation pass never claims another writer's envelope for a key it
minted.** The B1(a) read-before-write predicate compares
`(uid, deviceId, escrowKeyVersion, keySlot, recipientPublicKeyFingerprint)`.
Every one of those is a function of the recipient's roster pin, so the predicate
says nothing about **which key** an existing envelope wraps — the server never
sees key bytes and neither does the client check. For a generation already in the
ring that is harmless and required. For the generation a rotation is **minting**
it forked the team key:

> Admin A mints `K_A` for `v(N+1)`, publishes one envelope and dies before the
> callable, so the roster is still at `N` and `K_A` lives only in A's Keychain.
> Admin B rotates, mints a different `K_B`, claims A's envelope because all five
> fields match, and publishes `K_B` to everyone else. `rotateTeamKey` counts
> coverage and cannot see the fork, so the rotation is recorded. A then seals
> future facts under `K_A` while labelling them `teamKeyVersion: N+1`, which
> `firestore.rules` accepts because it checks the label, not the key. Nobody can
> read them, and no later rotation repairs it.

The ruling, shipped in PR 2 and binding on every later caller:

- For a slot **minted in this pass** — pending in the ring, not yet promoted,
  i.e. not yet recorded by the roster authority — an existing envelope is
  accepted **only** when `wrappedBy == the current uid` (it is our own earlier
  attempt at the same pass). Any other writer means a concurrent or abandoned
  rotation by another admin, and the pass must **STOP** with a typed error
  (`TeamVaultKeyDistributionError.rotationConflict`) that tells the admin to wait
  for or take over that rotation. It must never claim it.
- For **ring-sourced** slots (retained generations, the slug key) the B1(a)
  predicate stands unchanged. Every admin holds identical bytes for those, and
  requiring `wrappedBy == uid` would break PR 1 amendment N-2 — a departed
  admin's pre-departure wraps must stay valid so a survivor can finish the
  promote they started.
- **Taking over an abandoned rotation requires a NEW version `N+2`.** If the
  pending version's envelopes on the server are all `wrappedBy` one other admin
  and that admin's rotation is abandoned, `v(N+1)` is unrecoverable by anyone
  else: its key exists only in their Keychain, its envelope documents are
  create-only and immutable, and nothing publishable identifies which key a wrap
  carries. The roster still records `N`, so the only safe path is to rotate again
  to `N+2` and abandon `v(N+1)`'s partial envelopes in place — harmless, because
  the rules pin every fact write to the roster's active version, so no document
  can name a generation the callable never recorded.
- **PR 4 constraint.** Recovering an abandoned generation instead of only
  refusing it needs an opaque `wrappedKeyId` on the envelope
  (`CloudVaultCrypto.vaultKeyID`, already publishable — it is what
  `TeamKeyBootstrap.slugKeyId` exposes), which touches the rules `hasOnly` list
  and the callable's field allowlist. PR 4 owns that design, and owns the
  operator-facing wording for `rotationConflict`.

**Flag 1 — `schemaVersion == 2` is now behaviourally pinned in all three
callers.** The B3 ruling kept the clause out of `validSealedPayloadShape` and
repeated it in `validCloudSealedPayload`,
`validPathBoundCloudSealedPayloadAt` and `validRoamingProfileSealedPayload`, and
the file's comment claimed that deleting any one of the three would fail a test.
Only the first was true. PR 2 adds
`test_a_path_bound_sealed_payload_above_schema_version_2_is_rejected` and
`test_a_roaming_profile_sealed_payload_above_schema_version_2_is_rejected`;
relaxing the clause to `>= 1` in each caller now fails exactly one test each
(mF → `not ok 94`, mG → `not ok 95`, mH → `not ok 96`). Any future factoring of a
rules clause carries the same obligation: a repeated clause is only "still
enforced" if each copy is killed by its own test.

**Flag 2 — a generation the roster recorded is openable even if the local
promotion failed.** `rotateTeamKey` promotes `v(N+1)` from pending to active only
after the callable returns. If that Keychain write throws, the roster records
`N+1` while the minting Mac holds it as pending only — and the next rotation's
rewrap would count the entire corpus it had just re-sealed into
`skippedDocuments` for ever. `TeamCloudVaultRewrapWorker` therefore falls back to
the **pending** ring slot when a generation has no active entry, and logs it. The
fallback cannot resurrect an abandoned mint, because the rules pin every fact
write to the roster's active version, so no document can name a generation the
callable never recorded.

### Amendments from the PR 1 Cursor security round (2026-09-06)

Four MEDIUM findings raised by the Cursor agentic security reviewer on PR #2536,
after the F1–F11 and N-1–N-6 rounds had already closed the first two waves of
race and denial-of-key defects. All four reproduced; all four are fixed on
`feat/team-memory`. These **amend §3(b) and §3(c)** and are binding on PR 2–PR 4.
Where a ruling contradicts the design text above, the ruling wins.

**C-1 — a member may self-wrap only a generation the team has ALREADY
published.** F1's admin-or-self `create` closed peer squatting but left the
FUTURE open. Envelope ids are `{uid}_{deviceId}_{escrowKeyVersion}_v{N}` and are
create-only, so an ordinary active member could self-wrap the exact ids the next
rotation will demand of them, addressed to any key but their pinned one, and
occupy those ids permanently. `rotateTeamKey` then failed coverage on the
fingerprint mismatch and could not repair an immutable document: one member
could deny the whole team its only revocation primitive while keeping the
current key. `firestore.rules` now confines a self-wrap to
`keySlot == "slug"` or `keySlot == "v" + string(activeTeamKeyVersion(teamId))`;
an admin still publishes the next generation. **PR 2 constraint:** the rotation
client must publish v(N+1) envelopes as an ACTIVE ADMIN. A member self-wrapping
its own v(N+1) will be denied by the rules, by design.

**C-1 residual, named rather than closed.** A *currently active admin* can still
occupy a future generation's ids. That is inside the F1 trust boundary (an admin
is the key-distribution authority), it is attributable — `wrappedBy` is pinned to
the author and every mutation lands an `audit_log` row — and rotation names the
offending envelope id when it refuses. It is nonetheless the one remaining
permanent-DoS primitive in this lane, and its repair is a *bounded forward step*
in `rotateTeamKey` (accept `newKeyVersion > activeKeyVersion` within a small
window instead of strictly `+1`) so a poisoned generation can be stepped over.
That change weakens §3(c)'s "strict `activeKeyVersion + 1`" and is deliberately
NOT taken in PR 1. **Take it in PR 2 only if multi-admin mutual distrust becomes
an explicit requirement**; if it is taken, `test_rotate_rejects_a_non_sequential_key_version`
must be rewritten rather than deleted.

**C-2 — the last-admin guard decides inside the eviction transaction.** The
query-then-write guard was a count both halves of a race could satisfy: the last
two active admins leaving simultaneously each observed the other and each
committed `status: "removed"`. A team with no active admin is unrecoverable —
clients may not write `team_rosters/**` and every remaining callable requires an
active admin — so this froze the roster and its key-control plane for ever,
including the ability to rotate away the departed admins' wraps. `removeMember`
now re-reads the target row AND up to `MAX_ADMIN_GUARD_READS` (20) surviving-admin
candidates inside the transaction that evicts, and contends on the team document
as well. The refusal direction is the safe one.

**C-3 — `promoteMember`'s `status == "pending"` precondition is re-read inside
the writing transaction.** The old check ran before a wide envelope-coverage
window and the commit then merged `{status: "active"}` blind, so a `removeMember`
landing in that window was reversed by the promotion. **The live/removed re-join
invariant is: a removed member returns only through a fresh, single-use invite —
never through an admin race.** `commitGuardedByTeamState` takes a
`stillPendingMemberRef` and refuses `failed-precondition` if the row is anything
but `pending` at write time.

**C-4 — the team document carries `membershipEpoch: int`, and every guarded
commit runs under it. This is a NEW REQUIRED FIELD on
`team_rosters/{teamId}`.** `rotateTeamKey`'s requirement set comes from a QUERY
for `status == "active"`, and Firestore cannot conflict-detect a query: a
`promoteTeamMember` landing between the scan and the commit added an active
member the rotation had required no wrap for, changed neither `activeKeyVersion`
nor `retainedKeyVersions`, and so sailed past both N-4 guards — publishing
v(N+1) over the new member's head. That is the F3 active-but-blind invariant
reached through membership instead of key state. The epoch is the read a
rotation can conflict-detect on: `createTeam` seeds `membershipEpoch: 0`, and
`promoteMember` and `removeMember` bump it inside their transactions, so a
membership change during a rotation aborts the rotation instead of corrupting
it. It also fixes an unreported adjacent defect — a rotation that raced a
removal used to clear the `keyRotationRequired` flag that removal had just set.

- **PR 2–PR 4 constraint:** any new callable that moves a member INTO or OUT OF
  the active set must bump `membershipEpoch` in the same transaction, and any new
  decision computed from a roster query must commit through
  `commitGuardedByTeamState`. `removeMember` reads the epoch with
  `readMembershipEpoch`, deliberately not through `readTeam`: eviction must keep
  working on a team document whose key state is malformed, or a bad team document
  becomes the very freeze C-2 closes.
- The guarded-commit plumbing moved to `functions/src/teamRosterState.ts`
  (`readTeam`, `auditRef`, `auditEvent`, `commitChunked`,
  `commitGuardedByTeamState`, `readMembershipEpoch`). `teamRoster.ts` is back to
  490 lint-counted lines against the 600 ceiling, which is the headroom PR 2's
  additions need.
- Shipped rules size is now **151,123 B** against the 153,600 B fail line —
  **2,477 B of headroom**. The standing PR-2 blocker is unchanged and now
  tighter: PR 2 must land a compaction in the same PR.

### PR2 round 3 rulings (2026-09-06)

Controller rulings issued after the scoped re-review of PR 2, round 3
(`/private/tmp/claude-502/memprog/team-pr2-review-r3.md`, REQUEST_CHANGES: B5,
B6, B7 blocking, plus four nits). These **amend the B1 and B4 rulings above and
§3(c)**, and are binding on PR 3–PR 4. Where a ruling contradicts anything
earlier, the ruling wins.

**B5 — a rotation pass PRE-SCANS every envelope it would claim before it writes
any of them.** The B1(a) read-before-write check was interleaved with the write,
one `(device × slot)` at a time, and `rotateTeamKey` called `wrapKeys` once per
member over a caller-supplied `[String]` with no ordering contract anywhere. So
a conflict was detected only when the pass happened to REACH an occupied id: two
admins iterating the same roster in different orders each covered the members the
other had not reached yet before refusing, leaving `v(N+1)` carrying two
different keys — wedged for both, while the doc comment, the operator-facing
error text and the PR body all claimed "nothing was written".

`wrapKeys` now takes the whole recipient set and runs three phases: RESOLVE every
`(member, device, slot)` target, PRE-SCAN every envelope id — existence, the
five-field address check, and the B4 `wrappedBy` check for minted slots — and
only then WRITE. Any refusal leaves the server byte-identical, independent of
member order. **Binding on PR 3–4:** any new caller that publishes envelopes for
more than one recipient passes them in ONE call; the "nothing was written"
property is not preserved by looping over a single-recipient entry point.

**B6 — `mintedInThisPass` is set from the ROSTER, never from the local ring's
pending flag.** The invariant the B4 guard wants is "the roster has not recorded
this generation as active/retained". The code tested `mintKey`'s `isPending`, a
property of one Mac's Keychain, and the two came apart exactly where it mattered:
`loadKeyRingFromEnvelopes` stored ANY envelope-sourced slot straight into the
ACTIVE ring — including a `v(N+1)` whose callable never ran, which is precisely
what the launch-time key pickup finds after an abandoned rotation — after which
`isPending` was false and the guard switched itself off on the one pass it exists
to protect.

Two halves, both required:

- `rotateTeamKey` sets `mintedInThisPass = [newSlot]` unconditionally. The
  sequence guard already proves the roster has not recorded that version.
  `bootstrapTeamKeys` likewise passes `[v1, slug]` unconditionally.
- `loadKeyRingFromEnvelopes` reads the team document FIRST and stores an
  envelope's slot as ACTIVE only if the roster names it — `activeKeyVersion`, a
  member of `retainedKeyVersions`, or `.slug` once `slugKeyId` is a non-empty
  string. Everything else is stored PENDING: still reachable through
  `requireKey`, never mistaken for a generation the team published. A missing or
  unreadable team document yields an empty recorded set, so nothing is promoted.

`mintKey`'s `isPending` return value is DELETED, so it cannot be re-wired to that
question. **Binding on PR 3–4:** `openTeamFact` still reads the ACTIVE slot
before the pending one (B1(b)); what changed is which slot a loaded envelope
lands in.

**B7 — the escape hatch from a burned generation is REAL, and it is server
side.** The round-2 ruling said a takeover requires rotating to `N+2`. That was
false: the client refuses anything but `activeKeyVersion + 1`, and so does
`rotateTeamKey` (`Expected newKeyVersion to be ${team.activeKeyVersion + 1}`). A
team whose `v(N+1)` ids are occupied by a departed admin's wraps was therefore
**permanently unable to rotate**, which is permanently unable to revoke — and the
shipped `rotationConflict` text sent the operator in a circle. PR 2's scope is
widened to `functions/src/` to fix it.

- **New roster field `burnedKeyVersions: number[]`** on `team_rosters/{teamId}`,
  server-written only. `firestore.rules` needs no change — the roster is already
  `allow write: if false`, and that blanket denial is what makes the field
  server-owned; a rules test pins it. `createTeam` seeds `[]`.
- **New admin-only callable `abandonTeamKeyGeneration(teamId, version)`.** Three
  preconditions, all required: `version` must be the next NON-burned version
  after `activeKeyVersion`; it must be neither the active version nor in
  `retainedKeyVersions`; and at least one envelope for `v{version}` must exist,
  so it burns a real abandoned rotation rather than punching holes in the
  sequence. It appends in a transaction guarded by `membershipEpoch` (and by the
  key state) and audit-logs `key_generation_abandoned`.
- **`rotateTeamKey`'s strict-sequence check becomes "the next non-burned
  version"** (`nextRotatableKeyVersion` in `teamRosterState.ts`). On a team that
  has burned nothing this is identical to `activeKeyVersion + 1`, so
  `test_rotate_rejects_a_non_sequential_key_version` is unchanged.
- **`burnedKeyVersions` joins `TeamGuardState`.** An abandon landing inside a
  rotation's window moves the version that rotation is allowed to mint, so it
  must abort it, exactly as a key-state or membership move does.
- **Client:** `TeamVaultKeyDistributor.abandonConflictingGenerationAndRotate`
  calls the callable for `N+1`, DELETES that generation's pending key from the
  ring (`TeamVaultKeyRing.deletePendingKey`, backed by a new
  `CloudVaultKeyStore.deleteKey`), and runs a fresh rotation minting `N+2`. The
  two calls are deliberately not one transaction: a crash between them leaves
  `N+1` burned and the roster at `N`, which is the state a plain retry resumes
  from.
- **The `wrappedKeyId` work is still PR 4's**, and it is a different thing:
  RECOVERING an abandoned generation rather than stepping over it. The one real
  recovery that exists today — an admin whose own device received an A-written
  `v(N+1)` envelope opens `K_A` — lands as a PENDING slot and does not license a
  takeover, because nothing publishable proves the other members' ids carry the
  same key.
- **A burn spends one of a team's 100 key versions** (`validCloudSealedBlob` caps
  `keyVersion` at 100 and `rotateTeamKey` refuses to pass it). PR 4 owns
  surfacing the remaining budget.

**Nits 1–4, all fixed.** PR body counts corrected (23 → 27 Swift cases; the rules
baseline at `a153635e3c` is 95, not 94);
`test_a_non_abort_refusal_from_the_roster_authority_is_not_mistaken_for_a_stale_snapshot`
injects the `failed-precondition` its comment names; the `wrapKeys` doc comment
no longer claims an abandoned `v(N+1)` is "unrecoverable by anyone but them".

**Round 4 (2026-09-06) — B8 amends the B7 client bullet above.**
`abandonConflictingGenerationAndRotate` takes the conflicting generation as a
PARAMETER (`conflictingVersion`, which the caller already holds: the
`rotationConflict` it is recovering from carries the slot) and never re-derives
the burn target from `activeKeyVersion` + `burnedKeyVersions`. Re-deriving made
the "a crash between them leaves `N+1` burned and the roster at `N`, which is the
state a plain retry resumes from" sentence above FALSE: on the second press the
refreshed `burnedKeyVersions` already contains `N+1`, so the derivation returned
`N+2` and the retry burned the generation the Mac had just minted — two of a
hard-capped 100 versions per aborted retry. The retry now resumes: a version
already in the caller's `burnedKeyVersions` skips the callable entirely, and
`abandonKeyGeneration` is idempotent server side for a version it has already
burned (returns the roster's state, writes nothing, logs no audit row), so a
stale list resumes too. A `rosterStateMovedInFlight` abort of the INNER rotation
is retried as a ROTATION ONLY, reusing `N+2`'s pending key and its already
published envelopes. Nits: the `wrapKeys` "any refusal leaves the server exactly
as it found it" claim is scoped to the pre-scan (phase 3 can leave partial
writes); `rosterRecordedSlots` no longer claims an UNREADABLE team document
yields an empty set (`getData()` propagates the `permission-denied`); and the
`burnedKeyVersions` entry in `TeamGuardState` gains the two function tests that
kill its removal. **Binding on PR 3–4:** any caller of the recovery passes the
version the refusal named.

### PR3 review rulings (2026-09-05)

Controller rulings issued after the adversarial review of PR 3
(`/private/tmp/claude-502/memprog/team-pr3-review.md`, REQUEST_CHANGES: H1, H2
blocking, 5 MEDIUM, 5 LOW). These **amend §3(a) and §3(d)** and are binding on
PR 4. Where a ruling contradicts the design text above, the ruling wins.

**H1 — convergence is resolved by the CLIENT; the author pin does not move.**
`firestore.rules` keeps `request.resource.data.uid == resource.data.uid` on
update, with no admin exception: authorship stays immutable. The second member
to write a converged document is therefore refused by design, and the client
must not treat that as an error to retry. Before writing a team fact it READS
the document; if it exists and `uid != me`, the fact is already in the team
space under another author, the client records the convergence locally and moves
on with **no cloud write**. If it exists and `uid == me`, the existing
conditional-`updatedAt` path applies.

The convergence RECORD is the pull half of the same cycle: the teammate's
document comes down, lands in `agent_memory_inbox`, and the engine folds it into
this member's lineage under the namespaced `sync_identity:team:<teamID>:<key>`
ledger. No new app table and no migration is taken for it (the app control plane
has no durable key-value surface, and §3(e) forbids a new table); the cycle
report carries a `convergedForeignAuthor` counter and the event is logged per
document with its opaque doc id.

A per-document failure of any kind is caught, counted and logged **per
document** — one denied write must never abort the batch — and the team PULL
runs regardless of the push outcome: push and pull are separate `do/catch`
blocks inside the per-team cycle. Reading a team's memory does not depend on
being able to write to it.

**The pre-creation DoS is inside the member trust boundary and is NOT closed.**
A slug-key-holding member can derive and pre-create a document id another member
would converge on. They can only create it with their own rules-pinned uid and a
blob sealed under a key they legitimately hold, and the audit log names them.
State it in the PR body's threat model; do not try to prevent it.

**H2 — authorship is bound end to end.** `TeamMemoryPullService.verify` compares
the sealed payload's `authorUID` with the outer, rules-pinned `data["uid"]` and
refuses with a **PERMANENT** `.authorMismatch` — a document whose sealed author
disagrees with the uid the rules pinned is a forged document, not a transient
state, so freezing on it would let one forgery strand a member's whole lane. The
`authorUID` that reaches `payloadJSON` / `history_meta` is therefore the OUTER
uid: admission required byte equality, so the sealed copy IS the pinned one.

**MEDIUM-1 — the 90-day inbox sweep rewinds team cursors** exactly as the
personal sweep rewinds its own. Every predicate meaning "this account's inbox
cursors" now matches both shapes (`<uid>` and `team:%:<uid>`), with an exact
tail comparison rather than `LIKE`, because a uid containing `_` or `%` would
otherwise be a wildcard.

**MEDIUM-2 — team inbox rows are keyed per account.** `agent_memory_inbox
.doc_id` is the table's PRIMARY KEY, so keying on `(doc_id, user_id)` would need
a migration, which this PR does not take. The reviewer's second option ships
instead: team rows park under `team:<teamId>:<uid>:<cloud doc id>`. The inbox
doc id is a purely local handle — the daemon acknowledges by `(user_id, doc_id)`
and the engine treats it as an opaque token — and this lane resolves no forget
receipts against it (PR 1 review F7), so nothing downstream needs it to be the
cloud id.

**MEDIUM-3 — the team seam is a protocol.** `TeamMemorySyncCycling` is injected
into `MemoryCloudSyncDomain`, so a throwing double drives the real `sync()`.
`test_team_sync_failing_closed_does_not_affect_member_sync` now asserts the
personal cycle's own state (no error, an advanced date, a committed watermark);
the six-lever truth table survives under
`test_the_team_gate_is_a_strict_subset_of_the_personal_gate`.

**MEDIUM-4 — `teamProjectId` is bounded at BOTH ends**, to
`^[A-Za-z0-9_.:-]{1,128}$` (the engine's `REMOTE_WRITER_DEVICE_RE` shape). The
`.openburnbar/project.json` reader drops and counts an out-of-shape entry; the
pull refuses the document (`.projectIDOutOfShape`, permanent); the engine
refuses it (`REMOTE_PROJECT_ID_RE` → `INVALID_PROJECT_ID`), because `project_id`
is load-bearing for convergence and cannot be dropped the way attribution can.

**MEDIUM-5 — the fleet ceiling has a producer.**
`SettingsManager.applyTeamMemoryRemoteConfig` is called on both Remote Config
beats in `refreshComputerUseRemoteConfigOnce` — the cached value before the round
trip and the active value after it — beside `applyUsageMemoryRemoteConfig`, with
`memory_team_sync_enabled` seeded true in `commercialRemoteConfigDefaults`.
Resolution is required and resolution alone is not permission.

**LOWs.** L1: the pull's file header now names exactly which outer fields are
authenticated (`updatedAt`, `uid`) and warns PR 4 off matching a forget receipt
against the unauthenticated outer `sourceRefHmacs`. L2: `TIMELINE_META_KEYS`
moved to `constants.py` (`_read.py` was AT its 1500-line module ceiling, which is
why the keys had been crammed onto one line). L3: the `MemorySecretPIIGate`
memories × teams cost is noted at the call site as the first thing to memoise.
L4: an account switch no longer discards the incoming member's own team cursors.
L5: the PR body says plainly that a forget does not travel yet.

### PR3 round 3 rulings (2026-09-06)

Controller rulings issued after the round-3 scoped re-review of PR 3
(`/private/tmp/claude-502/memprog/team-pr3-review-r3.md`, **APPROVE_WITH_NITS**,
eight nits R1–R8). These **amend §3(a) and §3(d)** and are binding on PR 4.
Where a ruling contradicts the design text above, the ruling wins.

**R1 — the org ceiling seam is a NAMED NO-OP, and PR 4 must not wire it as a
one-liner.** #2534 (`OrgMemoryRemoteConfigSnapshot` / `isOrgMemorySyncAllowed()`)
is on `main`, and therefore on this branch's base — the earlier reason for
leaving it out of `TeamMemorySyncGate` ("that branch is not this one's base") is
dead and has been removed from both places that asserted it. The DECISION is
unchanged, on #2534's own stated grounds: `isOrgMemorySyncAllowed()`'s doc
comment says it is "Deliberately NOT ANDed into any member-local gate", because
member memory that was never org-gated must not be brickable by an absent, stale
or denying org ceiling — and `TeamMemorySyncGate` is a member-local gate (every
lever it reads comes from the member's own settings and the member's own roster
row). Whether a TEAM lane, unlike a member's personal one, SHOULD be org-gated
is a design ruling that has not been made. **PR 4 takes that ruling before it
adds the `&&`**, and does not treat the seam's one-line shape as permission.

**R5 — the team PUSH watermark is a SIBLING ROW in `remote_sync_watermarks`,
kind `memory_facts_team_push`.** The bound on the push read bill (a memory is
considered only when `updatedAt > watermark`) needs a durable per-`(team,
member)` instant, and §3(e) forbids a new table or a migration in this wave.
It rides on the existing table under the team lane's own account key
(`team:<teamId>:<uid>`, `TeamMemoryPullService.watermarkAccountKey`), which makes
it per-team and per-member for free. Two hosts were investigated and REJECTED,
and both findings are durable facts about the schema rather than preferences:

* **`lastSyncedAt` on the pull cursor's own row cannot hold it.** The row has
  five columns and none is free: `lastProcessedRemoteUpdateAt` IS the pull
  cursor, and `advanceWatermark` rewrites `lastSyncedAt` to `Date()` on every
  successful PULL. A push instant stored there would be dragged forward by
  unrelated inbound traffic and would then declare edited memories clean —
  silent non-contribution, the exact failure the bound must not introduce.
* **`KnowledgeSyncService` has no push tracking at all** to reuse; it re-derives
  what to upload every cycle. There was no existing push-watermark precedent in
  the app to follow, which is why this lane mints one.

The kind is deliberately NOT a `RemoteSyncCollectionKind` case (nothing PULLS a
collection by that name, so no sync loop may iterate it), which also keeps it
invisible to the daemon's consent-marker reader, whose query pins
`collectionKind = 'memory_facts_device_sync_marker'`.

**R6 — team OPT-OUT invalidates that team's push watermark.** Ruled YES, and
implemented in this round. A push watermark asserts "everything eligible as of
then was resolved", and that stops being true the moment the member switches the
team off: the Mac stops evaluating that team's eligible set while memories go on
being edited and retired. Re-opting in above a surviving row would push only what
changed during the OFF period and skip everything already clean — a member who
believes they are sharing and is not. The invalidation follows the personal
lane's EAGER-PURGE precedent (`MemoryDeviceSyncInboxGuard` acts on consent
wherever the state is observed, rather than waiting for a pull consent has just
forbidden): `TeamMemorySyncDomain.runCycle` is where the opted-in set is
observed, so it drops the push watermark of every team NOT in that set, before
the empty-set return — the case that matters most is a member leaving their ONLY
team. Scope is exact and pinned by test: this member only (tail-compared with
`substr`, never `LIKE`, so a `_` inside a uid stays a literal), this collection
kind only (the team's PULL cursor rides on the same account key and survives),
and no write at all when there is nothing to drop. **PR 4 owns the opt-out UI and
inherits this**: the lever it lands must go through the same cycle-observed path,
and if PR 4's opt-out ever deletes a member's cloud contributions, this
invalidation is what makes a re-opt-in republish them.

**R7 — the dirty filter's sub-millisecond tie is a NAMED RESIDUAL, not a code
change.** The filter skips `updatedAt <= watermark` and the watermark is
`MemoryCloudSyncDomain.syncStartedAt`, captured before the personal half. A
local write whose `updated_at` truncates to exactly that instant and commits
after the eligible-memories query has run would sit on the bar for ever.
Widening to `<` would close it at the cost of re-reading the whole boundary class
every cycle, on a clock the write and the cycle do not share; the personal lane
tracks no push instant at all, so the residual is strictly narrower than the
precedent it is measured against. Documented at the filter and listed as risk 3's
third residual, with the same operator recovery as the other two: delete that
team's push-watermark row.

**R8 — the two untagged `try?` this lane adds are OUTSIDE
`scripts/debt/check-try-optional-budget.sh`'s scope (`AgentLens/Services`) and
are now tagged anyway.** `BurnBarProjectCodeMemoryStore.syncInboxDiscriminators`
(an unparseable payload IS a personal entry) and the ordering test's personal
watermark probe (a throwing read is the "no" the assertion catches). Tagged so a
later widening of the script's scope reads them as reviewed rather than as a
regression from this PR. `live=0` remains an honest number.

**R2–R4 — PR body corrections.** Four commits, not three, in the rollback
section; `TeamMemorySyncTests` is 35 cases after this round, not 30; the
validation matrix's Drift and Lint rows are re-stated from this round's own runs
(the pbxproj WAS regenerated twice this round, to resolve the rebase's one
conflict) rather than carried over from the previous one.

### PR3 Cursor rulings (2026-09-06)

Controller rulings issued after the Cursor security round on PR 3 (three threads,
T1–T3, plus the round-5 follow-up below). These **amend §3(a) and §3(d)** and are
binding on PR 4. Where a ruling contradicts the design text above, the ruling
wins.

**The invariant all three rulings serve.** *Team-origin data may only ever touch
team-namespaced rows in a project explicitly linked to that team. It can never
match, overwrite, supersede or delete a personal row, even one sharing an engine
id or a body hash.* Stated in the code at `memory_engine/_namespaces.py`'s module
docstring.

**T1 (HIGH) — a fact-lane document may never carry forget semantics.** `verify`
decodes a typed payload that ignores unknown keys and then parks the RAW
plaintext, which the engine reads `entryKind` out of. The ability is REMOVED
rather than narrowed: `TeamMemoryPullRejection.factCarriesReceiptSemantics`,
PERMANENT (a forged receipt must not be able to freeze a whole team's lane, the
same argument as `.authorMismatch`), checked on the raw plaintext and
deliberately wider than the engine's own test. A team forget arrives only as a
verified `forget_receipts/*` document, which PR 4 owns.

**T2 (HIGH) — a team row's local engine id is DERIVED, never the sealed one.**
`_namespaces.py::_team_local_memory_id` hashes `(teamID, convergence identity)`,
so the attacker-chosen sealed `memoryID` is not an identity on this lane, and
`_local_memory_id` filters every remote-supplied id by the row's stamped
provenance in both directions.

**T3 (MEDIUM) — the landing partition comes from the LOCAL link, and the refusal
is lossless.** A sealed `teamProjectId` is admitted only by appearing in
`.openburnbar/project.json`'s `teams.<teamId>.teamProjectId` for a repository
this Mac has recorded; anything else is `.projectNotLinkedToTeam`, refused and
counted, fail-closed on an empty set or a store error.

That refusal is **PERMANENT** — freezing on it would let one repository nobody
on this Mac has cloned stall every OTHER project's team facts, a denial of
service any member could trigger by accident — and it is made **lossless** by a
rewind rather than by weakening the refusal:

> **REWIND ON A NEW LINK.** The pull records, per `(team, member)`, the set of
> linked `teamProjectId`s it observed at the last successful pull. When the
> CURRENT set contains an id the record does not, that team's pull cursor is
> discarded before the scan, so every document refused before the link existed is
> re-scanned and lands. Refused until linked, **recovered on link**.

The shape, which PR 4 inherits and must not regress:

* **No new table, column or migration.** One row per `(team, member, linked
  teamProjectId)` in the existing `remote_sync_watermarks`, under the same
  `team:<teamId>:<uid>` account key as the pull cursor and the push watermark,
  with `collectionKind = "memory_facts_team_link:<teamProjectId>"`
  (`RemoteSyncWatermarkStore.teamMemoryProjectLinkKindPrefix`). The same
  free-form-`collectionKind` device the push watermark already uses.
* **One row per project, not a hash of the set.** The rule is a SUPERSET test:
  gaining a link rewinds, LOSING one does not — nothing became readable, and
  re-reading the collection to refuse the same documents again is pure cost. A
  hash can only say "changed", which cannot tell the two apart.
* **These rows are not cursors.** `lastProcessedRemoteUpdateAt` is NULL and
  nothing reads it. Every predicate meaning "an inbox cursor" names its kinds
  exactly, so no rewind or advance reaches them by accident.
* **To the beginning, not to the oldest refused instant.** No such instant is
  recorded — recording one is a column this PR may not take — and the epoch floor
  of `memory_facts` is the safe direction. Parking is idempotent
  (`upsertRemoteMemoryFact` is keyed on `(doc_id, remote_updated_at)`), so a
  rewind costs reads and nothing else.
* **Opting a team out clears the record**, on the same trigger and for the same
  reason as the push watermark: while a team is off this Mac stops observing its
  links, so a surviving record would let a repository linked during the OFF
  period read as "already known" and the recovery rewind would never fire. The
  account-switch purge drops these rows too.
* **A first cycle is not a rewind.** `clearWatermark` reports rows deleted, and a
  gain against a cursor that does not exist yet is a no-op, not a rewind — so
  `rewoundForNewProjectLink` stays false and no rewind appears in a fresh
  install's log.

**T4 (MEDIUM) — the pull-time link check is necessary and NOT sufficient; team
rows are fenced again on the READ.** T3 admits a document into the project the
member's checkout links to the team. Two things survive it. First, a team
document seals its own `engineScope`, and the engine reads `scope = 'personal'`
as cross-project by design — so a team fact admitted correctly into project P was
then served into EVERY other project on the Mac, which is team-authored text in
front of a model working in a repository linked to nothing. Second, a link is a
file and a file can be deleted; T3 runs once, when the document arrives, and the
row then lives in the store for ever.

So the invariant above gains its serving half, binding on PR 4:

> **Team-origin rows are served by recall / search / ask / briefing /
> context-pack ONLY into sessions whose current project is linked to that team in
> this checkout's `.openburnbar/project.json`, and only when the row's landing
> project is exactly the `teamProjectId` that link names. Removing the link stops
> the serving on the next call.**

The shape:

* **One predicate.** `memory_engine/_namespaces.py::_team_row_servable(team_id,
  landing_project_id, session_project_id, links)`. Row provenance on the left,
  session on the right. A row with no `teamID` returns True and is decided by the
  pre-existing project fence exactly as before — the fence says nothing at all
  about personal rows.
* **The link set is read live, per call, and never cached.** `_session_team_links`
  reads `<projects.primary_path>/.openburnbar/project.json` bounded to
  `TEAM_PROJECT_LINK_MAX_BYTES` (2048, the app's `TeamProjectLink.maxBytes` byte
  for byte) and screens both halves of every entry to `REMOTE_TEAM_ID_RE` and
  `REMOTE_PROJECT_ID_RE`. Absent, unreadable, oversized, malformed or
  out-of-shape all mean "this checkout links nothing", fail-closed. Caching it
  would make unlinking take effect on the next daemon restart instead of the next
  call.
* **The link set carries the project it was read for.** `_SessionTeamLinks` is a
  pair, and the predicate refuses a set read for a different project rather than
  trusting its caller to have paired them — a fence whose inputs can be
  mismatched in silence is not a fence.
* **Every serving path routes through it**: `recall` (and therefore
  `recall_pack`, `ask` and `session_briefing`, which are recall with a renderer
  on top), `list`, `get`, `history`, `timeline`, `entities`, `relations`.
  `include_cross_project` does not widen it — that flag opens the PROJECT fence,
  and this is a different one.
* **`list`'s SQL clause is BUILT by the predicate, not a restatement of it.**
  `list` counts and paginates in SQL, so its fence must be SQL or `total` and the
  page boundaries would describe rows the caller never receives. Every
  `(teamID, landing project)` pair the store holds is put to the predicate and
  only the admitted pairs are bound into the clause, so there is no second copy
  of the rule to drift — which is what
  `test_the_serving_fence_is_the_only_thing_holding_a_team_row_back` (neuter the
  predicate, the leak returns on recall, `list` and `timeline` alike) depends on.
* **`burnbar_context_pack` needs no gate.** It serves indexed code chunks from
  the local repository (`project_code_memory.py:3574`, via `search_code`), not
  engine memories; team rows cannot reach it.
* **The Swift app needs no gate either.** Its only memory recall surface reads
  `agent_memories` (`AgentLens/Services/DataStore/ControlPlaneStore+MemoryRecall.swift:6`),
  and the team pull's only landing table is `agent_memory_inbox`
  (`AgentLens/Services/CloudSync/TeamMemoryPullService.swift:340`), from which
  only the engine merges. No Swift file reads the engine's `memories` table.

**T5 (MEDIUM) — the serving fence covers reads; the WRITE path had no fence at
all.** T4 gated every path that serves a body. `remember` serves nothing and so
passed straight through it, while still loading its candidate pool with
`_load_active(project_id, include_personal_cross_project=True)`. A team row
sealed `engineScope = "personal"` was therefore a live near-duplicate / judge /
conflict candidate in a project linked to no team: a near-duplicate reinforce
returned the TEAM body and the team row id to that session (the T4 leak through
a surface that never calls recall), the judge could answer UPDATE or DELETE
naming the row, and a negation cue could retire it outright.

So the invariant gains its third and last face, binding on PR 4:

> **Team-origin rows are invisible to every WRITE-path candidate set —
> near-duplicate, judge, conflict, supersede, retire, alias, update, forget — and
> a write initiated by the local user never mutates or retires a team-origin row
> in ANY session, linked or not. It may only create a personal row (or a new team
> contribution through the sealer). Team rows change through the team lane —
> pull, receipts — or through an explicitly team-scoped operation, and through
> nothing else.**

The shape:

* **A second predicate, deliberately stronger than the first.**
  `_namespaces.py::_team_row_writable_by_local_user(team_id, *, team_scoped)` is
  False for every team-origin row unless the caller declares itself the team
  lane. It does not consult the link file, because linking a project grants READ
  and never authorship — the linked session is fenced exactly as hard as the
  unlinked one. That single rule subsumes T5's visibility half: a row no local
  write may change has no business in any local write's candidate set, so
  `_team_write_filter` drops team rows from every session's pool rather than only
  from unlinked ones.
* **`_team_row_servable` stays load-bearing on this side too**, in the one place
  it still decides something: HOW MUCH A REFUSAL MAY SAY. An unlinked session may
  not learn the row exists, so it gets the same `TEAM_PROJECT_NOT_LINKED` the
  read surfaces return; a linked session may see it, so its refusal names the row
  and the reason (`TEAM_ROW_NOT_WRITABLE`). One helper,
  `_team_write_refusal(memory_id, ...)`, builds both, so the surfaces cannot
  drift into disagreeing about what a refused write says.
* **`team_scoped` is a real flag, not decoration.** The merge's own two
  retirements (`_sync.py::_decide_remote_fact`'s live-clash convergence and
  `_converge_stale_duplicate`) pass `team_scoped=bool(team_id)` — the team lane
  retiring the row a later team revision superseded — and `_row_is_addressable_by`
  above each of them is what earns it. Every local path leaves the default False,
  so a new write path is fenced by omission rather than opened by it.
* **Every local-user write surface is a caller.** `_commit_fact`'s pool (and so
  `remember`, `memorize`, `import_memories`, every extractor batch) and its
  exact-duplicate reinforce; `update`; `review`; `forget`, on the RESOLVED alias
  id, so a redirection cannot carry a hard delete into a team row; `forget_all`,
  in SQL, so the preview, the selection token and the delete agree; `fold`, on
  BOTH ends; `_retire`, as defence in depth for whatever the next retirement
  caller turns out to be; and `doctor --apply`'s parked-supersede reset.
* **The identical-body answer is CONVERGENCE REPORTED, not "create a personal
  row".** In the linked project the store's `UNIQUE(project_id, scope,
  body_hash)` is already occupied by the team row on exactly that triple, so
  there is no second row to write and reinforcing the team row is the thing being
  forbidden. `remember` returns `NONE / TEAM_ROW_NOT_WRITABLE` naming the row,
  which a linked session is entitled to see. A *near*-identical body is a
  different triple and does get its own personal row, in the member's own
  lineage, which the ledger namespacing (T2) already keeps separate.
* **Recall's access bookkeeping is deliberately NOT fenced.**
  `_reinforce_recall_ids` bumps `access_count` / `last_accessed_at` / salience on
  rows a session was already entitled to read — it never touches body, lineage or
  lifecycle, it cannot fire on a row the T4 fence refused, and blocking it would
  break the "last helped" ordering T4 exists to serve. Stated here rather than
  left for a reader to notice.
* **Layout.** The gating pushed `_read.py` and `_write.py` past the 1500-line
  bound, so the destructive surfaces moved into one new module,
  `memory_engine/_lifecycle.py` (`_retire`, `_history`, `fold`, `forget`,
  `_purge`, `forget_all`): every path that ends a row's life, behind the one
  predicate that now fences all of them. `_read.py` 1515 → 1374, `_write.py`
  1553 → 1350, `_lifecycle.py` 378.
* **Both predicates are mutation-proven.** Forcing
  `_team_row_writable_by_local_user` to True turns 4 tests red (the reviewer's
  reinforce comes straight back, id and all); forcing `_team_row_servable` to
  True turns 6 red, two of them the new write-path disclosure tests.


---

### Amendment A1 — the landing partition is not a local project id (2026-09-06)

**Found by:** the two-clone proof (`tools/openburnbar-mcp/tests/test_team_two_clone.py`, PR #2542).

**The defect, plainly: a team fact contributed with `engineScope = "project"` landed correctly and then appeared in no recall surface on any member's Mac, including its own author.**

`teamProjectId` is deliberately NOT a local `proj_<32hex>` id. That indirection is
the whole cross-member convergence mitigation: two members' checkouts of the same
repository mint different local ids, and a team fact has to converge across them,
so it lands in the partition the shared repository names
(`memories.project_id = "burnbar-core"`). T4 then added the serving fence
*beside* the pre-existing LOCAL project fence rather than in place of it for team
rows, and that composition is the bug — `(m.project_id = ? OR m.scope =
'personal')` compares a `teamProjectId` against a local project id, values from
two different namespaces, so it is false for every project-scoped team row in
every session on every Mac. The row passed every write and admission check, sat
in the store, answered `_team_row_servable(...) is True` when asked directly, and
was filtered out of `recall`, `recall_pack`, `ask`, the session briefing, `list`,
`timeline`, `entities`, `relations` and `export`. Only `engineScope = "personal"`
team facts reached a model, and only by accident: a personal row is cross-project
by the engine's own design and so survived the local fence.

**The ruling (binding).**

> A team row is servable in this session **iff this checkout's
> `.openburnbar/project.json` links that team to exactly the `teamProjectId` the
> row landed in.** The session's own local `proj_` id is not part of the
> comparison, because a team landing id and a local project id are different
> namespaces by design.

**The shape.**

* **One predicate, and now genuinely the only one.** `_team_row_servable` was
  already comparing the right pair. What changed is everything around it: every
  query that carries the local project fence widens it with
  `constants.TEAM_ROW_PRESENT_SQL` (`json_extract(m.metadata_json, '$."_burnbar".team.teamID') IS NOT NULL`),
  and the Python-side fences do the same with `_metadata_team_id(...) is None`,
  so a team row reaches the predicate instead of being dropped before it.
  Widening a `SELECT` grants nothing: what it selects is handed straight to the
  predicate.
* **Every call site, consistently.** `engine.py::_load_active` (the pool for
  `recall`, `entities`, `relations`, and — behind `_team_write_filter` — every
  local write); `_read.py::recall`'s `include_superseded` branch and its
  `allowed()` predicate; `_read.py::list`'s project fence, beside the SQL clause
  `_team_visibility_sql` already built from the predicate; `_read.py::timeline`'s
  `FOREIGN_PROJECT` refusal, which is skipped for a team row that the team fence
  above has already admitted and is unchanged for every personal row;
  `_admin.py::export`'s narrow project fence.
* **`export`'s count becomes honest.** A narrow export used to drop team rows in
  SQL, so `teamRowsWithheld` was 0 while rows were being withheld — a backup
  silently short of the team memory the member is entitled to. It now selects
  them and the fence withholds and counts them.
* **`timeline`'s `FOREIGN_PROJECT` is not weakened.** A team row's landing
  partition is always "foreign" to a local project id; the team fence, which runs
  first and is strictly stronger for those rows, is the one that decides them. B8
  still guards every personal row exactly as before
  (`test_the_landing_partition_rule_leaves_personal_rows_alone`).
* **The Swift pull side does not mirror the defect and needed no change.**
  `TeamMemoryPullService` admits a document with
  `linkedTeamProjectIDs.contains(payload.projectID)` — a set membership within
  the `teamProjectId` namespace, never a comparison against a local project id.
  The daemon's `agent_memories` table is a separate store that the team lane
  never writes to.
* **The PR3 convergence note is corrected.** T5 said a local `remember` of an
  identical body in the linked project would collide with the team row's
  `UNIQUE(project_id, scope, body_hash)` and return `NONE /
  TEAM_ROW_NOT_WRITABLE`. That assumed a team row lands on the local project's
  triple, and it does not. The member gets their own personal row in their own
  project; the team row is not reinforced, superseded or retired, because
  `_team_write_filter` keeps it out of every local write's pool in every session.
  The lock is unchanged — only the description of where it bites.
* **Named residuals, unchanged by A1.** `reindex`, `memory_analytics` and
  `aux_secret_exposure` stay fenced to the local project: they serve no body, no
  id and no lineage, and leaving them fenced discloses strictly less. A
  consequence worth stating: a team row's vectors come from the merge that landed
  it, and a per-project `reindex` will not re-embed one — `reindex(all_projects=True)`
  is the operation that does.

**The six security properties, each preserved and each pinned by a test** (all in
`tools/openburnbar-mcp/tests/test_memory_blind_sync.py`):

| Property | Test |
| --- | --- |
| A checkout that links nothing serves nothing | `test_a_checkout_that_links_nothing_serves_no_project_scoped_team_row` |
| A checkout linking a DIFFERENT `teamProjectId` for that team serves nothing | `test_a_checkout_linking_a_different_team_project_serves_nothing` |
| A checkout linking a different TEAM serves nothing | `test_a_checkout_linking_a_different_team_serves_nothing` |
| Removing the link stops the serving on the next call | `test_removing_the_link_stops_serving_a_project_scoped_team_row_at_once` |
| Personal rows are unaffected | `test_the_landing_partition_rule_leaves_personal_rows_alone` |
| The write fence and the local-write lock are untouched | `test_the_landing_partition_rule_leaves_the_write_fence_untouched` |

**Both forms of the rule agree, and both mutation directions are proven.**
`test_the_sql_and_python_forms_of_the_serving_rule_agree` walks the same six
fixtures through `_team_visibility_sql`'s clause and the in-Python predicate and
through the surfaces built on each. Forcing `_team_row_servable` to `True` serves
the row into an unlinked checkout on every surface
(`test_mutation_neutering_the_serving_predicate_serves_the_row_everywhere`);
restoring the landing-vs-session comparison hides it from the LINKED checkout on
every surface, which is the defect itself
(`test_mutation_the_old_landing_versus_session_comparison_hides_the_row_again`).

### D16 Cursor ruling — the link file is a committed, confirmed decision (2026-09-06)

**Block 11, and the only block in this file that was NOT copied from the design
session's source.** It is a controller ruling issued on PR #2542 after the source
session ended, recorded here because the ruling itself directed that it be, and
marked as a local block so the byte-identical claim in this file's header stays
checkable over blocks 1–10. Where it contradicts anything above, the ruling
wins — including over block 10 (amendment A1) immediately above, which it does
not contradict but narrows: A1 says a team row is servable iff this checkout's
`.openburnbar/project.json` links that team to the row's landing partition, and
clause 2 below fixes which bytes of that file count as the link.

The finding (Cursor, HIGH, `tools/openburnbar-mcp/memory_engine/_namespaces.py:859`):
a first-time `link_team_project` write proceeded with `confirmed=False` — only a
re-point was gated — `burnbar_memory_doctor` was ungated and flagged the ordinary
`syncedOnThisMac && !linkedInThisCheckout` state with a `fix` naming the tool,
and `RecordedRootTeamProjectLinkResolver` / `TeamProjectLink.read` used the
WORKING-TREE `.openburnbar/project.json` rather than git `HEAD`. So an agent, or
a prompt-injected tool call, in a private checkout on a Mac that already synced
the team could create that file with no human confirmation and no commit, and
that checkout's approved engine memories became eligible to upload under the
teammates' agreed `teamProjectId`.

§3(a) called this file "a checked-in, human decision". The ruling makes the code
enforce that sentence, in three clauses.

**Clause 1 — every write is confirmed, not only a re-point.**
`burnbar_team_link_project` refuses a first-time write without `confirm=true`
(`LINK_REQUIRES_CONFIRMATION`) exactly as it refuses a re-point
(`LINK_ALREADY_SET`), and the refusal states what would become uploadable. The
two codes stay distinct because they are different decisions: a member who meant
to create a link should learn that one already exists, not merely that they
forgot a flag. What is at stake was never the file's previous contents — it is
what the file makes publishable, and on a Mac already syncing the team the FIRST
write is precisely the one that publishes.

**Clause 2 — eligibility follows the COMMITTED link.** Both readers —
`TeamProjectLink.read` (upload eligibility and pull admission) and
`memory_engine/_namespaces.py::_session_team_links` (the T4 serving fence) —
honour an entry only when the working tree and `HEAD` name the same
`teamProjectId` for that team.

* Committed and unmodified → a link.
* Working tree only (never committed, or committed and then re-pointed) → NOT a
  link. Nobody agreed to it.
* `HEAD` only (deleted or edited out locally) → NOT a link either. This preserves
  the property the fence was built for: taking a link away stops the lane on the
  very next call, without waiting for a commit.
* No git work tree, unborn branch, git missing or git hung → NOTHING is a link.
  Fail closed, as the ruling directs: a directory with nothing checked in has
  checked in no decision, and a reader that could tell those cases apart is a
  reader that could be talked into treating "no repository" as "committed".

The intersection is taken **per entry, not per file** — the one place the shipped
rule is narrower than the ruling's literal text, and deliberately. Failing a
dirty file closed as a whole would let an in-progress edit adding team B silently
unlink team A, whose entry `HEAD` carries and the team agreed to weeks ago.
Nothing is gained by that collateral: the attack is an entry `HEAD` does not
carry, and per-entry closes exactly it, in both directions.

The git read is bounded the way the file read is (`git show HEAD:<path>` streamed
to `maxBytes + 1`, refused whole if over) and is skipped entirely when the
working tree names nothing, so a checkout with no link file still costs one
`stat` and no subprocess.

**Clause 3 — the doctor reports, and does not read as a remediation script.**
`TEAM_PROJECT_LINK_GAPS` gains `linkWrittenButNotCommitted` /
`uncommittedTeamIDs` as their own dimension — "you wrote this link and did not
commit it" is a different sentence from "this team has no entry here", and
collapsing them is what made an uncommitted file look like a working link. The
finding carries a `decision` field stating that linking makes this checkout's
approved memories eligible to upload to that team, readable by every member now
and in future, and that this is a human decision and not a step to run because a
report mentioned it. `fix` names the tool, its `confirm=true`, and the commit.
There is still **no `apply`**, and none is added.

**Where the working-tree read survives.** Only in reporting: the doctor's
`workingTreeTeamProjectID` / `linkWrittenButNotCommitted`, the writer's
`effective` / `committedTeamProjectID` / `nextStep`, and the
`team_memory_project_link_not_committed` log dimension. No fence reads it.

**Tests** (`tools/openburnbar-mcp/tests/test_team_two_clone.py`, plus the Swift
twins in `AgentLensTests/Active/TeamMemorySyncTests.swift`):
`test_an_unconfirmed_uncommitted_link_makes_nothing_uploadable` is the reported
path as the thing that must not happen; `test_a_first_time_link_is_refused_without_confirm`,
`test_only_a_committed_link_makes_a_project_eligible`,
`test_an_uncommitted_link_serves_no_team_row_into_this_session` and
`test_the_doctor_reports_an_uncommitted_link_as_uncommitted_not_as_linked` take a
clause each; `test_only_a_committed_team_project_link_is_eligible` and
`test_a_link_file_outside_any_repository_publishes_nothing` mirror clause 2 on the
Swift half so the two readers cannot drift; and
`test_the_three_ruling_clauses_are_each_load_bearing` restores each clause's
pre-ruling behaviour and names the test that goes red.

`test_team_two_clone.py`'s own `_team_project_id_for` — the doc-id pre-image's
project half, and the mutation target of the two-clone proof — now asks the
engine's own reader instead of re-parsing the file, so that proof rides on the
shipped eligibility rule rather than on a second implementation of it.
