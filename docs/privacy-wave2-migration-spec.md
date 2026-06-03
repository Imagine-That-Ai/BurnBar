# Privacy hardening — Wave 2 migration spec (HELD)

**Status:** specified, NOT started. **Why held:** every Wave-2 change rewrites
`CloudVaultCrypto` + ~40 native call sites + `hermesGateway.ts`, and the
`codex/format-functions-callables` refactor is *actively* editing those exact
files (a mid-air `File has been modified since read` collision was already hit on
`hermesGateway.ts`, and `FirestoreRepository.kt`/`AgentBrandZoneView.swift` were
being written second-by-second). **Do not start until that refactor lands/merges;
re-pull and re-verify the call-site list first** — line numbers below are
indicative, not authoritative.

Wave 1 (already landed): F6 fail-closed `usage`/`budgetRules` + Android writer,
F5a `knowledge_repos` strict rules + index + doc honesty, F7 searchable-index
disclosure, F8 scanner server-source gates. Commits `edee4da0a` + `f7c16a046`.

## 0. The one migration principle that governs all of Wave 2

**Only the device holds the vault key**, so a server-side backfill of sealed data
is *impossible*. Every Wave-2 reformat MUST be **lazy dual-read**:

1. Bump the envelope/record `schemaVersion` (v1 = legacy, v2 = hardened).
2. **Readers accept both**: try v2 (AAD-bound / keyed); if the stored
   `schemaVersion == 1`, fall back to the legacy open with no AAD / raw hash.
3. **Writers always emit v2.** Existing v1 rows re-seal opportunistically the
   next time a key-holding device rewrites them (the codebase already follows
   this "sealed-first, legacy fallback, a key-holding peer reseals" pattern).
4. Never delete the v1 read path until telemetry shows zero v1 rows served.

No forced cutover, no downtime, no data loss. Each section says what "v2" means.

---

## 1. F2 — CloudVault AAD context binding (High; largest)

**Goal:** a sealed blob can no longer be relocated to a different field / doc /
purpose under the same key. Bind AES-GCM additional authenticated data (AAD) to
the blob's context, mirroring the convention `HermesRelayCrypto` already uses
(`OpenBurnBar-HermesRelay-v1|…`, see `HermesRelayCrypto.swift` `aad(_:)`).

### 1.1 Canonical AAD string (byte-identical on all four surfaces)

```
OpenBurnBar-CloudVault-aad-v1|<uid>|<collection>|<docId>|<field>
```

- `<uid>` — Firebase uid that owns the doc.
- `<collection>` — the logical subcollection under `users/{uid}/`, e.g.
  `usage`, `budgetRules`, `media_attachment_manifests`, `agent_identities`,
  `subscription_topics`, `approval_policies`, `rollback_requests`,
  `cli_sessions`, `session_logs`, `project_memory_snapshots`,
  `mobile_assistant_chats`, `knowledge_sync_manifests`, `knowledge_repos`,
  `text_expansion_snippets`.
- `<docId>` — the Firestore document id the blob is stored under.
- `<field>` — the sealed field name, e.g. `sealedProjectName`, `sealedLabel`,
  `sealedFilename`, `sealedDisplayName`, `sealedScope`, `sealedBody`,
  `sealedRootPath`, `sealedRepoFullName`.

UTF-8 bytes, `|`-joined, parts must not contain `|` (uid/docId/field never do;
collection is a constant). The blob's `vaultKeyID`/`keyVersion` are already
authenticated by the key itself; the load-bearing additions are
uid+collection+docId+field. `schemaVersion: 2` on the envelope signals "AAD-bound
with aad-v1".

### 1.2 Per-surface API change

| Surface | File | Change |
|---|---|---|
| Swift | `OpenBurnBarCore/.../CloudVaultCrypto.swift` (sealText ~124, sealBlob ~138, sealPayload ~167; open* ~178) | add `aad: Data` param (or a typed `CloudVaultContext` builder mirroring `HermesRelayCrypto.aad`); thread into `AES.GCM.seal(…, authenticating: aad)` / `AES.GCM.open(…, authenticating: aad)` |
| Kotlin | `android/.../data/cloud/CloudVaultCrypto.kt` (~67) + `CloudVaultCryptoSupport` | `cipher.updateAAD(aadBytes)` right after `cipher.init(...)` on BOTH encrypt and decrypt |
| Node (mcp-remote) | `tools/openburnbar-mcp-remote/src/seal.ts` (~19) + `decrypt.ts` | `cipher.setAAD(aadBuf)` / `decipher.setAAD(aadBuf)` |
| WebCrypto (console) | `apps/console/lib/escrow.ts` (~338) | pass `additionalData` in the `{ name: "AES-GCM", iv, tagLength }` params on encrypt AND decrypt |

### 1.3 Dual-read

Openers: if `envelope.schemaVersion >= 2`, open WITH the computed AAD; if it
throws or `schemaVersion == 1`, open WITHOUT AAD (legacy). Writers always seal at
`schemaVersion: 2` with AAD. A v1 blob reseals to v2 on the next write by a
key-holder.

### 1.4 Call sites to thread context through (~40 — RE-VERIFY post-refactor)

Each site must pass the exact `(uid, collection, docId, field)` it writes/reads.
From the audit (indicative): MediaAttachmentManifestStore, BudgetRulesStore,
ActivityStore, MobileTextExpansionStore, AgentBrandZoneView, ApprovalPolicyStore,
CLIAgentMissionDispatcher, AgentReplyNotificationService, RollbackService,
MobileChatHistoryStore, PensieveKnowledgeChunker, CLIAgentSessionRecord,
ConversationCloudVaultPayload, UsageSyncService, SessionLogSyncService, AgentLens
CloudBudgetService; Android RollbackService.kt, AssistantChatHistoryStore.kt,
CLIAgentMissionDispatcher.kt, AgentSubscriptionTopicStore.kt, ThreadInboxStore.kt,
FirestoreRepository.kt, TextExpansionSyncManager.kt, AgentReplyNotificationReceiver.kt;
console repoDisplay.ts.

### 1.5 Tests + gate

- Interop unit tests (Swift `CloudVaultCryptoTests`, Kotlin `CloudVaultCryptoTest`,
  console interop): **opening a v2 blob with a mismatched context (different field
  or docId) MUST throw.** Same plaintext under two contexts → different ciphertext.
- Round-trip v1→v2 dual-read test.
- Scanner: add the deferred `scan-chat-cloud-plaintext.mjs` static assertion that
  `CloudVaultCrypto.swift` binds a constant AAD prefix into seal/open (so a
  regression that drops or attacker-controls AAD fails red). **This is the only
  scanner assertion intentionally left out of Wave 1** — it would have failed
  before F2 lands.

---

## 2. F3 — keyed hashes (High)

**Goal:** remove the raw-SHA-256 confirm-the-guess oracles.

- Add to `CloudVaultCrypto` (Swift + Kotlin + TS) keyed digests mirroring the
  existing `pensieveDedupHash` (HKDF<SHA256>(vaultKey)→HMAC):
  `bodyHmac(info:"sessionlog-body:v1")`, `chunkHmac(info:"sessionlog-chunk:v1")`,
  `snapshotContentHmac(info:"projectmemory-content:v1")`.
- `SessionLogSyncService.swift`: `bodyHash = sha256Hex(markdown)` → `bodyHmac(...)`;
  `chunkHash = sha256Hex(chunk)` → `chunkHmac(...)`. Resolve the vault key BEFORE
  the dedup short-circuit so the compare uses the keyed value. Stamp
  `bodyHashVersion`/`chunkHashVersion` (start at 2) on manifest + chunk + search
  docs; treat a version mismatch as "needs re-upload" → transparently re-keys
  legacy rows on next sync. Keep `sourceVersionID` equal to the keyed `bodyHmac`
  (it is only an opaque version tag).
- Project memory: stop emitting raw `snapshot.contentHash` at the commit; either
  drop it (keep it a local-only SQLite column) or replace with
  `snapshotContentHmac`. Confirm `commitEncryptedProjectMemorySnapshot` only uses
  it for opaque change-detection.
- `CloudVaultBlobEnvelope`: remove `plaintextSHA256` (Swift ~51 + Kotlin ~40 + TS
  shape). AES-GCM's tag already authenticates integrity; if defense-in-depth is
  wanted, store a keyed MAC under a derived integrity subkey. Bump
  `CloudVaultBlobEnvelope.schemaVersion`; accept the legacy field optionally on
  decode (verify only when present).
- `dataExport.ts`: remove `bodyHash`/`contentHash` from the opaque-export
  allowlist (~line 240-293) for end_to_end/zero_access domains unless version-gated
  to the keyed form. Leave the already-keyed `tokenHashes`/`semanticHashes`/
  `slugHmac`/`dedupHash`. Add a `dataExport.test.ts` assertion that no raw
  `bodyHash`/`contentHash` survives for an E2EE domain.
- Scanner/rules: flag any `bodyHash`/`contentHash`/`hash`/`plaintextSHA256`/
  `sourceVersionID` field on an end_to_end/zero_access collection unless a sibling
  `*HashVersion >= 2` marks it keyed.

---

## 3. F4 — opaque Pensieve sync manifest (High, partial)

**Goal:** stop leaking the source path/identity in `knowledge_sync_manifests`.

- `knowledgeMemory.ts` `configureKnowledgeSource`: stop deriving the doc id from
  the path (`slugify(rootPath)` ~424). Accept a client-supplied opaque
  `slugHmac` (the same vault-keyed HMAC `commitKnowledgeBatch` already keys
  vectors on) via `requireHexDigest`, and use `safeCloudDocumentID(slugHmac)` as
  the manifest id — so manifest, vectors, and search filter all key on the same
  opaque id. Drop the cleartext `rootPath` + `repoInstallId` fields; replace with
  optional `sealedRootPath` (a `CloudVaultSealedText`, `requireSealedText`) and, if
  needed for routing, an `HMAC(installId)` token (never the raw id).
- Client (`KnowledgeSyncService.swift` ~196 + `PensieveKnowledgeChunker.swift`):
  compute `slugHmac = pensieveSlugHmac(slugify(sourcePath), vaultKey)` BEFORE
  `configureKnowledgeSource`; pass it as the opaque id and pass
  `sealedRootPath = sealText(sourcePath, vaultKey)` instead of
  `rootPath: item.sourcePath`. Remove cleartext `rootPath`/`sourceSlug` from the
  `KnowledgeSyncCallable` protocol.
- Migration: existing manifests are keyed by the cleartext slug → new ones by
  `slugHmac`. Lazy: the device reconfigures (idempotent) on next sync under the
  opaque id; the old doc is purged by `deleteKnowledgeSource`/reconcile.
- Scanner: assert `knowledge_sync_manifests` lacks `rootPath`/`repoInstallId`/
  `sourcePath` and that its id/`sourceSlug` is a 64-hex `slugHmac` (mirror the
  existing `knowledge_repos` block). Fix the rules comment at the manifest match
  to state the real invariant.

---

## 4. F5b — per-user repoMatchToken + drop cleartext sourceSlug (High, partial)

**Goal:** make `repoMatchToken` non-cross-user-linkable and remove the reversible
`sourceSlug` (F5a already locked the rules + index + doc honesty).

- `knowledgeSync.ts` `repoMatchTokenFor`: derive per-user —
  `HMAC(globalKey, uid + "|" + normalize(fullName))` — so the token is no longer
  globally deterministic. The webhook (knows `full_name`, not `uid`) can no longer
  match by one equality, so **invert the lookup**: maintain a server-only fan-out
  index `HMAC(globalKey, normalize(fullName))` → set of `{uid, perUserToken}`,
  written by `connectKnowledgeRepo`, queried by the webhook. If the fan-out index
  itself is deemed acceptable global leakage, document it explicitly.
- Replace stored cleartext `sourceSlug` on `knowledge_repos` with
  `sourceSlugHmac` (`pensieveSlugHmac`); this couples with F4 (the manifest doc id
  becomes the opaque `slugHmac`, so the webhook→manifest hop uses it).
- Migration: the cleartext repo name is only seen transiently at webhook time and
  is NOT stored, so existing rows can't be re-tokenized server-side → existing
  connections must **reconnect** (client-driven) to gain a per-user token. Lazy +
  documented; old globally-deterministic rows remain readable meanwhile.
- The Wave-1 rule allowlist already forbids client-written `sourceSlug`; once the
  callable stops writing it, add it to the scanner's denylist.

---

## 5. F1 — gateway honesty flag + adapter sealing (Critical tail)

`hermesGateway.ts` protocol is already `2` (verified). Remaining:

- **Server honesty flag (no migration):** emit a per-client `sealed` boolean on
  `/state`, derived from `relayCapable`, so the phone UI never shows a "sealed"
  badge for a legacy plaintext client; gate any "end-to-end/sealed" marketing copy
  on `relayCapable === true` per client, not product-wide.
- **Adapter sealing (migration):** `tools/hermes-platform-burnbar/adapter.py`
  currently posts plaintext `text`/`fileName`. Seal via the `HermesRelayCrypto`
  contract (`p256-hkdf-sha256-aesgcm`, keyVersion 1) to the phone's relay public
  key (from `/state`); send a `relayEnvelope` instead of plaintext, and encrypt
  attachment bytes before upload. The agent must publish its own relay public key
  so `relayCapable` flips true. Until this ships, the live agent→phone path is the
  only remaining server-readable plaintext.
- **Grace-window kill switch:** move `HERMES_GATEWAY_GRACE_WINDOW_CUTOFF`
  (2026-09-01) behind Remote Config / a flag so plaintext acceptance can be killed
  without a redeploy once adapter adoption is confirmed (watch the
  `plaintext_body_deprecated` / `plaintext_filename_deprecated` counters).

**Coordination:** this file is the codex refactor's hot path — do F1 LAST, after
the refactor merges.

---

## 6. Execution order + what's verifiable here

Recommended order (smallest blast radius / most verifiable first):
1. **F5b** — server-TS + rules only; fully verifiable here (TS build +
   `test:firestore-rules` emulator + a `knowledgeRepoMatchToken.test.ts`).
2. **F4** — server-TS (`knowledgeMemory.ts`) verifiable here; Swift client needs Xcode.
3. **F3** — `dataExport.ts` + tests verifiable here; Swift/Kotlin crypto needs
   Xcode/gradle.
4. **F2** — the big one; CloudVault crypto across 4 surfaces. Swift/Kotlin
   compilation NOT verifiable in this CLI env (needs `xcodebuild` / `./gradlew`);
   land the canonical AAD + Swift reference impl + interop tests first, then mirror.
5. **F1** — last, after the gateway refactor merges.

Pre-flight before ANY Wave-2 edit: `git pull` the settled refactor, re-run the
verification workflow's call-site audit (line numbers will have moved), and
re-confirm `firestore-rules` 45/45 + scanner + `test:hermes-gateway` are green on
the merged base.
