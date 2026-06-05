# Domain Signalification Map — Stream 5 Policy

**Branch verified:** `fix/hermes-gateway-e2ee-remediation-20260603`
**Source of truth:** `packages/data-domains/registry.json` (schemaVersion 1, 12 domains)
**Scope:** every `encryptionTier: "end_to_end"` domain in the registry, plus an explicit accounting of what stays `server_readable`/`zero_access` and why.

This map is the **policy contract** for migrating BurnBar's at-rest E2EE domains from the current per-user **CloudVault** symmetric-vault-key sealing (`CloudVaultCrypto`, AES-256-GCM) to the official **Signal Protocol** (`@signalapp/libsignal-client@0.94.4`, AGPL-3.0-only, pinned in `third_party/libsignal/manifest.json`).

---

## 0. Honesty preamble — the three load-bearing facts

Verified against the live tree, not assumed:

1. **There is no Signal crypto to migrate to yet.** `packages/libsignal-bridge/src/index.ts` is a 45-line readiness stub: it exports `LIBSIGNAL_PIN`, `REQUIRED_SIGNAL_PROTOCOL_SYMBOLS` (11 names), and `assertOfficialLibsignalReady()` (symbol-presence filter only) and re-exports the raw `libsignal` namespace. There is **no** `signalEncrypt`/`processPreKeyBundle`/`SessionRecord` call anywhere in production Swift/TS. Every "target signalEnvelope treatment" in the table below is therefore **a target shape behind an off flag**, blocked on Stream 1 shipping a real X3DH + Double-Ratchet bridge API. `manifest.json:burnbarIntegration.status` is literally `"pinned-and-load-tested"`, not "shipped".

2. **The current end_to_end sealing is CloudVault, not a ratchet.** All four end_to_end domains seal with one per-user 32-byte vault key via `CloudVaultCrypto` (`OpenBurnBarCore/.../SharedModels/CloudVaultCrypto.swift`): `sealText` → `CloudVaultSealedText` (line 84), `sealPayload` → `CloudVaultSealedPayload` (line 146, `vaultKeyID`-bound), `sealBlob` → `CloudVaultBlobEnvelope` (line 112). AAD = `CloudVaultAADContext` (line 31), prefix `OpenBurnBar-CloudVault-aad-v2` (line 173, legacy `-v1` at line 174). Vault-key distribution is P-256 ECIES escrow (`wrapVaultKey`, line 641, info `OpenBurnBar-Escrow-v1`). **There is no Double Ratchet, no X3DH session, no forward secrecy in any at-rest domain today.**

3. **Architectural mismatch is the central risk, not the bridge.** Signal's Double Ratchet is a **pairwise sender↔recipient session**. CloudVault domains are **self-encryption** (a user seals to their own vault for later same-user reads across their own devices). A naive 1:1 ratchet is the wrong primitive for at-rest. The honest Signal mode for these domains is **seal-to-own-identity / Sender-Key (group)**, not a pairwise ratchet — this must be **designed**, and the policy below treats "signalEnvelope" as that self/group construction, never a 1:1 chat session.

Also verified: the April-2026 "scanner is blind to project_memory_snapshots / knowledge_repos / dataExport" claim is **stale**. `firestore.rules` now enforces `validProjectMemorySnapshotKeys()` (line 1812, bans `projectDisplayName`/`projectSlug`, requires `validCloudSealedBlob`) and `validKnowledgeRepoKeys()` (line 1978, bans `repoFullName`/`sourcePath`/`sourceSlug`, requires `validCloudSealedText` for `sealedRepoFullName`); `dataExport.ts:isSealedEnvelope` (line 320) is a default-deny structural recognizer. The genuine residual leak is the **deterministic keyed-HMAC search index** (admitted in the `session_logs` registry summary), which **Signal does not fix**.

---

## 1. The signalification map (one row per end_to_end domain)

The four `end_to_end` domains in `registry.json`, in **proposed migration order** (smallest blast radius first; the key layer `device_trust_keys` is the hinge and migrates last/parallel).

| # / Wave | Domain id (`registry.json` line) | Current sealing mechanism (verified) | Target signalEnvelope treatment | What stays server_readable, and why |
|---|---|---|---|---|
| **W1** | **`pensieve`** (L66, gate `burnbar_pro_max`) | `CloudVaultCrypto.sealText` → `sealedCiphertext` + `sealedMetadata` via `knowledgeMemory.ts:commitKnowledgeBatch`; cloaked 384-d vectors; vault-keyed HMAC `pensieveDedupHash` (L492) + `pensieveSlugHmac` (L502); repo identity sealed via `sealedRepoFullName` + opaque `repoMatchToken` (`knowledgeSync.ts`). Cleartext `contentHash`/`sourceSlug`/`sourcePath` already **rejected** (remediated 2026-06-02). | **Self/group Signal seal of `sealedCiphertext`+`sealedMetadata` only.** New `CloudVaultSignalEnvelope` field `{signalCiphertextBase64, signalSessionId, envelopeVersion}` carried **alongside** the existing CloudVault fields (additive, never replaces in W1's no-op PR). The ANN vector and HMAC dedup/slug stay **outside** the envelope (search must keep working). **First proving ground** (lowest traffic, smallest shapes, no Storage blobs, no recovery dependency). | `sourceKind`, cloaked 384-d vectors (the server runs ANN without reading them), `repoMatchToken` (opaque keyed), chunk/byte counts, timestamps. These are routing/aggregate facets, not content. The deterministic vector + dedup HMAC remain a *structural* leak that Signal does **not** close — the registry summary must keep stating this. |
| **W2** | **`conversations_chat`** (L30, gate `burnbar_pro`) | `CloudVaultCrypto.sealPayload` → `mobile_assistant_chats` (`MobileChatHistoryStore.swift:390/427`), `cli_agent_mission_requests` (`CLIAgentMissionDispatcher.swift:72`); `sealText` → `rollback_requests` (`RollbackService.swift:221`), `approval_policies` (`ApprovalPolicyStore.swift:308/316`), `agent_identities`, `subscription_topics`; opaque `subscriptionDocID` HMAC (L519). | **Per-collection self/group Signal seal of the body docs.** `sealPayload` body docs map cleanly to a single envelope; do it **per collection**, starting `cli_agent_mission_requests`, then `mobile_assistant_chats`. The smaller `sealText` fields (`approval_policies` globs, `agent_identities` personas) follow after the body docs prove the envelope. | `provider`/runtime identifiers, message counts, status/routing metadata, timestamps, device ids. Operational facets needed to list/route threads without reading them. `subscription_topics` keeps its opaque `subscriptionDocID`. |
| **W3** | **`session_logs`** (L48, gate `burnbar_pro`) | `CloudVaultCrypto.sealBlob` → Storage `session_logs/{documentID}/bodies/{bodyHash}.json.aesgcm` (`ActivityStore.swift:780`); `project_memory_snapshots` opaque `projectMemoryDocID` (L478) + `sealedSnapshot` blob; **deterministic keyed-HMAC search index** (`tokenHashes` L445, `searchIndexTokenHashes` L451, `semanticHashes` L585). | **Signal seal of the blob bodies only**, with an **explicit, separately-tiered search index** decision. The Storage blob body becomes a `CloudVaultSignalEnvelope` blob variant. **The HMAC postings index is NOT migrated** and **must be honestly re-tiered** — Signal forward secrecy fights searchability; keep the index as a documented structural leak, do not pretend the envelope closes it. **Hardest domain** (large Storage blobs + search). | `provider`, `model`, `cost`, token counts, timing, integrity hashes, and the **deterministic keyed search digests** — the registry summary already admits the server can learn recurring/co-occurring terms and confirm a guessed body via integrity hashes. This is the one place where `serverSees` legitimately includes a content-derived structure, and it stays. |
| **W4 (hinge)** | **`device_trust_keys`** (L202, no gate) | This **is** the key layer. `CloudVaultDeviceKeypair` (P-256, Keychain) + escrow graph: `cloud_vault_key_wrappers`, `escrow_public_keys`, `escrow_grants`, `escrow_envelopes`; `wrapVaultKey`/`unwrapVaultKey` P-256 ECIES (`CloudVaultCrypto.swift:641`, info `OpenBurnBar-Escrow-v1`); recovery via `account_recovery_methods`. | **Replace the P-256 ECIES vault-key escrow with a Signal identity-key + signed/one-time/Kyber prekey directory.** This is what `escrow_public_keys` (no signature today) and `cloud_vault_key_wrappers` become. **Riskiest** — touches recovery (`DataVaultRecoveryView.swift`) and the genuine-ciphertext-deletion guarantee. Do this **after** the body domains prove the envelope, or run a **parallel scheme + dual-write** during cutover so a half-migrated account is never locked out. | Device trust state, public-key **fingerprints** (the Signal safety-number input), and wrapped (ciphertext) key blobs. The vault/identity **private** key never leaves the device (Keychain / 0600 file). Fingerprints staying server-readable is what makes Stream 6's safety-number UX possible. |

**Domains that explicitly stay as-is (do NOT signalify):**

- **`zero_access`:** `computer_use` (L148, sealed escrow envelopes) and `media` (L166, iroh-relayed payloads + `sealedFilename` via CloudVault — `MediaAttachmentManifestStore.swift`, a **different key system**, out of scope to migrate; in scope only to name).
- **`server_readable` (legitimately):** `usage_spend` (L12 — telemetry/cost; project *names* already device-sealed), `provider_accounts` (L94 — labels only; secrets in GCP Secret Manager), `connected_devices` (L112 — **routing metadata**; the Hermes gateway/relay **frame contents are already sealed** via `HermesRelayCrypto` HPKE, a separate transport-layer migration owned by Streams 2/3/4, not this CloudVault stream), `external_mcp` (L130 — grant audit), `entitlements_billing` (L184 — billing must be server-readable by definition), `audit_timeline` (L220 — tamper-evident hash chain needs server append).

> **Registry honesty note (cross-stream, do not silently inherit):** Stream 3 flags that `connected_devices` is tiered `server_readable` while its gateway bodies are sealed end_to_end — the *machine-readable* tier the scanner keys off says `server_readable`. That is a **transport** envelope (HPKE), not a CloudVault at-rest envelope, so it is **out of Stream 5's lane**; correcting it is a coordinated Stream 0/registry edit. Stream 5 must not retag `connected_devices`.

---

## 2. Registry + codegen changes the migration needs

The registry is the single source of truth; `codegen.mjs` emits `gen/domains.ts`, `gen/DataDomains.swift`, `gen/DataDomains.kt`; `registry.test.mjs` byte-pins all three (plus the Android in-tree copy and `website/src/data/trust.generated.ts`).

### 2a. Additive registry fields (no tier flips in the no-op PRs)

The current registry schema has **no envelope/sealing-mechanism field** — `encryptionTier` is the only crypto signal, and it is a coarse `server_readable | zero_access | end_to_end` enum (`codegen.mjs:36 TIERS`). To express "this end_to_end domain is sealed with CloudVault vs Signal" **without changing the tier** (so the no-op PRs stay no-op), add a new **optional, additive** per-domain field:

```jsonc
// per-domain, optional; absent == legacy CloudVault sealing
"sealingScheme": "cloudvault" | "signal" | "cloudvault+signal-dual"
```

- **Default/absent = `cloudvault`** so every existing domain row is unchanged → `registry.test.mjs` byte-pin of `gen/*` and `trust.generated.ts` still passes with **zero diff** until a wave flips a value.
- A wave's cutover is then a **one-line registry edit** (`pensieve` → `cloudvault+signal-dual`, later `signal`), which regenerates `gen/domains.ts`/`DataDomains.swift`/`DataDomains.kt` and forces the apps + website trust copy to update **from one place** — exactly the drift-proofing the existing gate provides for the chat-label regression it was built to stop.
- `encryptionTier` **never changes** during signalification (all four domains stay `end_to_end`). Signal does not move a domain between tiers; it changes *how* the end_to_end seal is produced. Keeping the tier stable is what keeps the public `trust.generated.ts` honest and unchanged.

### 2b. Codegen changes (`codegen.mjs`)

- Add `sealingScheme` to the TS `DataDomain` interface (after `tieredLimits`), the Swift `DataDomain` struct, and the Kotlin `data class` — all three emitters (`emitTs`, `emitSwift`, `emitKotlin`). Default-emit `"cloudvault"` when absent so existing rows serialize identically (preserves the byte-pin).
- **`websiteSafe`/`splitSummary` must NOT leak the scheme name.** `sealingScheme: "signal"` is an internal crypto codename; the public `trust.generated.ts` must keep speaking the **tier** language only (`end_to_end` → "Only your devices"). Do not surface "Signal" on burnbar.ai via the registry — the `INTERNAL_CODENAMES`/codename-scrub policy in `codegen.mjs:276-302` is the precedent. The trust surface stays tier-only; the scheme is apps-internal.
- **Rule 0:** `codegen.mjs`, `driftcheck.mjs`, `registry.json`, `registry.test.mjs` are **NOT** AGPL-owned and are Stream 5's to edit. `packages/data-domains/package.json` **IS** AGPL-owned (license fields) — do **not** touch it; the codegen change needs no dependency add.

### 2c. New driftcheck/test assertions (turn paper guarantees into CI gates)

`driftcheck.mjs` today only proves every `users/{uid}/<col>` in `firestore.rules` is registry-covered (`findDrift`). Add, in `registry.test.mjs` (Stream-5-owned), assertions that bind `sealingScheme` to reality:

1. **Tier invariance:** assert no domain's `encryptionTier` changes when `sealingScheme` is `signal`/dual — a Signal domain is still `end_to_end`.
2. **Self-encryption guard:** assert any domain marked `sealingScheme: "signal"` is one of the 4 end_to_end ids (block accidentally signalifying a `server_readable` domain).
3. **Dual-write completeness (when a wave flips to `cloudvault+signal-dual`):** a follow-up test asserting `firestore.rules` accepts **both** the legacy `validCloudSealedText`/`validCloudSealedBlob` shape **and** the new `validSignalEnvelope` shape for that domain's collections — proving the legacy-read fallback is preserved.

---

## 3. How driftcheck + firestore.rules enforce the new shape

### 3a. driftcheck (`driftcheck.mjs`) — coverage, not crypto

`findDrift` (line 41) only proves **collection coverage** (every rules subcollection ∈ some domain's `firestorePaths` or `excludedCollections`). Signalification **adds no new collections** to any of the four domains (the Signal envelope is a **new field on existing docs**, e.g. a `signalEnvelope` sibling of `sealedSnapshot`), so `driftcheck.mjs` stays green untouched. The new enforcement lives in `firestore.rules` validators + the `registry.test.mjs` byte-pin (§2c), not in the path-coverage drift check. **Do not** weaken `driftcheck` to "tolerate" Signal — it should never need to know.

### 3b. firestore.rules — the per-doc shape gate is where Signal is enforced

Today the rules enforce the CloudVault shape with strict allowlists, verified live:

- `validCloudSealedText(value)` (line 453): `keys().hasAll([algorithm, keyVersion, nonce, ciphertext, tag])` **and** `keys().hasOnly([schemaVersion, algorithm, keyVersion, nonce, ciphertext, tag, aad])`, `algorithm == "AES-256-GCM"`, base64 regexes + size caps, and the `aad` must match `validCloudVaultAAD` (line 448, regex `^OpenBurnBar-CloudVault-aad-v2\|...`).
- `validCloudSealedBlob(value, expectedAAD)` (line 495) for `project_memory_snapshots.sealedSnapshot` (line 1838), AAD bound via `cloudVaultAADContext(userId, "project_memory_snapshots", docID, "sealedSnapshot")`.
- `validProjectMemorySnapshotKeys()` (line 1812) and `validKnowledgeRepoKeys()` (line 1978) ban every cleartext identifier and require the sealed field.

**The Signal migration enforcement is a parallel `validSignalEnvelope(value)` rule function, added additively:**

1. **New validator** `validSignalEnvelope(value)` with its own strict `keys().hasOnly([...])` allowlist for the Signal envelope shape — e.g. `{schemaVersion, envelopeVersion, signalCiphertextBase64, signalSessionId}` — base64-regex + size-capped, mirroring how `validCloudSealedText` is structurally rigid. **It must NOT loosen the existing allowlist** (do not add Signal keys to the CloudVault `hasOnly` set — that would let a CloudVault doc smuggle extra fields).
2. **Per-collection acceptance becomes an OR, fail-closed:** during a `cloudvault+signal-dual` wave, the doc-write rule for that collection accepts **`validCloudSealedText(field) || validSignalEnvelope(signalField)`** — never plaintext, never a third shape. After the wave proves migration telemetry (`manifest.json:migrationPolicy`: *"existing HPKE/CloudVault envelopes remain legacy read-only until migration telemetry proves old rows are gone"*), the CloudVault arm becomes **read-tolerant / write-rejected** (writes require the Signal shape; reads still open legacy), matching the existing **write-strict / read-tolerant** ladder the gateway uses for v1→v2→v3.
3. **AAD discipline must be preserved.** The CloudVault AAD binds `uid|collection|docID|field|schemaVersion|purpose` (`CloudVaultAADContext`, `cloudVaultAADContext` in rules line 444). The Signal envelope must carry an equivalent context-binding (the Signal AD field) so a relay/server cannot move a sealed value between docs/fields — fail-closed if the binding is absent. The rules validator should reject a Signal envelope whose bound context does not match the doc path, exactly as `validCloudSealedBlob` already passes `expectedAAD`.

### 3c. Server callable + dataExport enforcement (server-side, where rules can't see Admin-SDK writes)

- `shared.ts:requireSealedText` (line 390) and `dataExport.ts:isSealedEnvelope` (line 320) currently recognize AES-256-GCM CloudVault + HPKE relay/ratchet shapes. The migration adds an **`isSignalEnvelope(value)` recognizer** next to `isSealedEnvelope` (default-deny: structural match on `signalCiphertextBase64` + version constant, **never** decrypt) so **export and genuine-ciphertext-deletion stay correct the instant a Signal-sealed doc exists** — even before any producer writes one. This is the Stream-5 first-PR value: recognition lands ahead of production, so the export/delete guarantees never have a blind window.
- `dataExport.ts:sealAwareSerializeDoc` stays **default-deny**: a Signal envelope passes only via `isSignalEnvelope`; anything unrecognized still lands in `redactedFields[]`. No plaintext path is added.

---

## 4. Migration order & coexistence rules (the operational contract)

1. **PREREQ (Stream 1):** ship a callable libsignal bridge **and** define the **self-encryption Signal mode** (Sender-Key / seal-to-own-identity — *not* a 1:1 ratchet, because at-rest is same-user multi-device). Freeze a cross-language byte-parity fixture mirroring the `BurnBarHpkeV3Vector.json` lane (Stream 8). **Until this exists, every "signal" target below is shape-only behind an off flag.**
2. **W1 `pensieve`** → first PR: land `CloudVaultSignalEnvelope` struct (additive) + `isSignalEnvelope` recognizer + a fixture round-trip test, **flag OFF**, all writes still `CloudVaultCrypto.sealPayload`. Then flip `sealingScheme` to `cloudvault+signal-dual` once the bridge is real.
3. **W2 `conversations_chat`** → per-collection, body docs first (`cli_agent_mission_requests`, then `mobile_assistant_chats`).
4. **W3 `session_logs`** → blob bodies to Signal; **explicitly keep and re-tier the deterministic HMAC search index** (Signal does not solve searchability — say so in the registry summary, do not overstate).
5. **W4 `device_trust_keys`** → replace P-256 ECIES escrow with Signal identity + prekey directory; **dual-write + parallel scheme** during cutover to protect recovery and never lock an account out.

**Coexistence invariants (every wave):**
- **No tier flip** — all four stay `end_to_end`.
- **No downgrade** — a wave only emits Signal when both ends negotiate the capability (mirror the existing v2→v3 advertise-then-emit gate); legacy CloudVault rows stay openable read-only per `manifest.json:migrationPolicy`.
- **Search leak stays honestly disclosed** — the `session_logs` registry summary's existing "deterministic keyed search digests" admission is the model; do not delete it when bodies become Signal-sealed.
- **Server stays blind** — no Signal-path change may make a callable inspect plaintext.

---

## 5. Rule 0 / ownership boundaries for this stream

**Stream 5 may edit:** `registry.json`, `codegen.mjs`, `driftcheck.mjs`, `registry.test.mjs`, `gen/*` (regenerated), the CloudVault Swift sources under `OpenBurnBarCore/Sources/`, the `functions/src/callables/*` validators (`dataExport.ts`, `knowledge*.ts`, `encryptedSearch.ts`), and `firestore.rules` validator functions (coordinate — shared/driftchecked).

**Stream 5 must NOT touch (Rule 0 / AGPL or other-stream):** `packages/data-domains/package.json`, `packages/libsignal-bridge/**` (consume only), `Package.swift`/`Cargo.toml`/any `package.json` license fields, `functions/src/health.ts`, `functions/src/sourceMetadata.ts`, `services/*/src/server.ts`, `website/**` (the trust copy is *generated* into it by codegen, but the page files are AGPL-owned — regen output only, never hand-edit), `third_party/**`, and `connected_devices`'s transport (Streams 2/3/4). Work in a **separate worktree**; the AGPL agent is live in the main checkout.

## Open Questions (external-reviewer surface)

1. Self-encryption Signal mode is undecided: at-rest CloudVault is same-user multi-device (seal-to-own-vault), but Signal's Double Ratchet is pairwise. Must Stream 1 expose Sender-Key/group or a seal-to-own-identity construction? A 1:1 ratchet is the wrong primitive and would break multi-device same-user re-reads — this is an architecture decision, not a drop-in.
2. Searchability vs forward secrecy for session_logs: the deterministic keyed-HMAC search index (tokenHashes/semanticHashes) is the genuine residual structural leak and Signal does NOT fix it. Does the policy keep the index as an honestly-tiered separate structure, or invest in a different (e.g. ORAM/PIR-style) search that Signal forward secrecy doesn't fight? Current recommendation: keep + keep disclosing.
3. device_trust_keys recovery during cutover: replacing P-256 ECIES escrow (wrapVaultKey, account_recovery_methods) with a Signal identity+prekey directory risks locking out recovery_key/recovery_contact flows. Is dual-write + parallel scheme acceptable, or does recovery need a dedicated non-Signal escrow that survives the migration?
4. sealingScheme field naming + whether codegen should emit it to the website trust surface at all (current recommendation: NO — keep trust.generated.ts tier-only, scheme is apps-internal). Needs registry-owner sign-off since it touches the byte-pinned gen/* + trust.generated.ts gate.
5. Should the Signal envelope's context-binding (AD) reuse the exact CloudVaultAADContext grammar (uid|collection|docID|field|schemaVersion|purpose) so firestore.rules can validate it with the existing validCloudVaultAAD regex, or define a parallel Signal-AAD grammar? Reusing it minimizes new rules surface but couples two crypto systems' AAD formats.
