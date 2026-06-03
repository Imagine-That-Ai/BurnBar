I have the complete primitive inventory. There are TWO existing crypto stacks:
1. **`CloudVaultCrypto`** (vault-key AES-256-GCM): `sealText`, `sealBlob`→`CloudVaultBlobEnvelope`, `sealPayload`→`CloudVaultSealedPayload` — used for all data sealed to the user's own devices (conversations, snapshots, project memory).
2. **`HermesRelayCrypto`** (`p256-hkdf-sha256-aesgcm` ECIES `sealToBase64`): used for cross-endpoint relay where a `relayPublicKey` is exchanged (Mac↔phone relay link), NOT the vault key.

This is the crux of the gateway fork: gateway clients hold neither key. I have everything I need. Let me produce the design brief.

## DESIGN BRIEF: Privacy Remediation — Honesty (registry/trust/docs) + Scanner + Scrubber + Migration

All paths absolute under `/Users/albertonunez/Documents/Windsurf/BurnBar`.

---

### 1. DATA FLOW (writer → readers, file:line)

**A. Hosted chat gateway — `hermes_gateway_messages` / `hermes_gateway_events` / `hermes_gateway_attachments`** (registry domain `connected_devices`, line 117; rules `allow write: if false` at `firestore.rules:1971/1966/1981`, i.e. **server-written**):

- **Writer (server, plaintext):**
  - `functions/src/callables/hermesGateway.ts:465-477` — `handleMessageSend` writes `text` (the chat client's typed message body), `threadId`, `replyToEventId` as **cleartext** to `hermes_gateway_messages/{id}`.
  - `functions/src/callables/hermesGateway.ts:982-999` — `enqueueHermesGatewayEvent` writes `text` (the agent's reply / `/model …`) plus **`senderDisplayName`** (line 992) as cleartext to `hermes_gateway_events/{eventId}`.
  - `functions/src/callables/hermesGateway.ts:553-566` — `handleAttachmentInit` writes `fileName` (a filename, private) cleartext to `hermes_gateway_attachments/{id}`.
- **Readers:**
  - Server re-serializes verbatim: `serializeHermesGatewayEvent` at `functions/src/hermesGateway.ts:294-325` (returns `text`, `senderDisplayName` unchanged), streamed via `makeHermesGatewaySSE` (`functions/src/hermesGateway.ts:327`) and `handleEvents` (`hermesGateway.ts:436-449`).
  - End readers are the **gateway client** (a bearer-token HTTP client; grant doc at `hermesGateway.ts:753-766` carries only `tokenHash`/`tokenPreview`/`scopes` — **no key**) and the Mac agent runtime that polls `/events`.
- The server **never parses `text` for any logic** — pure store-and-forward.

**B. `hermes_relay_requests` + `/chunks` (already sealed — reference pattern):**
- Writer: native Mac/phone via rules `relayRequestWrite` (`firestore.rules:539-586`) / `relayChunkWrite` (`588-617`). Rules already require `schemaVersion >= 2`, reject `path/sessionId/body/error/data/text`, require `payloadCiphertext`, `wrappedKey`, `relayEncryption == "p256-hkdf-sha256-aesgcm"`. Native sealer: `AgentLens/Services/CloudSync/HermesRelayHostService.swift` + `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift:99` (`sealToBase64`). `pi_agent_relay_requests` mirrors this (`firestore.rules:688-...`, host `PiAgentCloudRelayHostService.swift`).

**C. `project_memory_snapshots/{projectSlug}` (registry domain `session_logs`, line 55):**
- Writer (Mac): `AgentLens/Services/CloudSync/SessionLogSyncService.swift:591-602` (`uploadProjectMemorySnapshot`) → callable `commitEncryptedProjectMemorySnapshot`.
- Server writer (plaintext): `functions/src/callables/encryptedSearch.ts:371-392` writes `projectDisplayName` (project name) cleartext + uses `projectSlug` (project-name-derived) as the **doc ID**. Body is sealed (`sealedSnapshot` = `CloudVaultBlobEnvelope`).
- Readers: `getEncryptedProjectMemorySnapshot` (`encryptedSearch.ts:414-431`) and the list variant (`468-477`) return `projectDisplayName` to the Mac. Native reader: `SessionLogSyncService.swift:609-633`. Server never reads `projectDisplayName` for logic.

**D. `knowledge_repos/{repoId}` (registry domain `pensieve`, line 73):**
- Writer (server): `functions/src/callables/knowledgeSync.ts:104-109` (`connectKnowledgeRepo`) writes `repoFullName` (e.g. `owner/secret-repo` — project-name-class), with `repoId`/`sourceSlug` derived from it.
- Reader **with server-read requirement**: `functions/src/callables/knowledgeSync.ts:73` — the GitHub push-webhook handler runs `db.collectionGroup("knowledge_repos").where("repoFullName", "==", repoFullName)` to route an inbound webhook to the user. **The server must read `repoFullName` in cleartext** — it cannot equality-match a vault-sealed value.

**E. `cloud_search_knowledge` (Pensieve vectors):** already hardened (B-SEC-2). `functions/src/callables/knowledgeMemory.ts:5-35` — device cloaks the vector with the vault key and AES-256-GCM-seals chunk text + metadata; server stores only cloaked vector + sealed envelopes + vault-keyed HMAC dedup; no cleartext `sourcePath`/`sourceSlug`/`contentHash`. **No change needed; only scanner coverage.**

**F. `media_*`:** registry tier `zero_access` (lines 164-180). `media_attachment_manifests` (writer rules `firestore.rules:2447`), `media_session_events` (`2096`), `media_quota_usage` (`2427`). Manifests carry filenames/labels. Needs scanner coverage; confirm `hasOnly()` + no plaintext filename in the manifest allowlist.

---

### 2. SERVER-READ REQUIREMENT (definitive)

| Surface | Server needs plaintext? | Verdict |
|---|---|---|
| `hermes_gateway_messages/events/attachments` `.text`/`senderDisplayName`/`fileName` | **No** — re-serialized verbatim (`hermesGateway.ts:294-325`), never parsed | **Seal-vs-honest-label = PRODUCT FORK** (key availability blocks E2E; see §3, §5) |
| `project_memory_snapshots.projectDisplayName` + doc-ID `projectSlug` | **No** — store-and-forward; body already sealed | **SEAL** |
| `knowledge_repos.repoFullName` | **Yes** — webhook correlation `where("repoFullName","==",…)` (`knowledgeSync.ts:73`) | **HONEST LABEL** (cannot seal without breaking webhooks) |
| `cloud_search_knowledge` | Already sealed; server runs ANN on cloaked vectors only | No change |

---

### 3. VAULT-KEY AVAILABILITY (the decider for the gateway)

- **`project_memory_snapshots`:** both reader (Mac) and writer (Mac) hold the vault key. **E2E sealing is fully possible.** (`SessionLogSyncService.swift` already resolves `writableVaultKey`/`readableVaultKey`.)
- **Hosted chat gateway:** the gateway **client** authenticates with a **bearer token only** — the grant doc (`hermesGateway.ts:753-766`) has **no vault key and no `relayPublicKey`/ECIES key**. The Mac runtime has the vault key; the external chat client does **not**. **Therefore vault-key E2E sealing of gateway bodies is impossible for the gateway-client reader** unless the client is upgraded to either (a) a vault-trusted device, or (b) an ECIES relay endpoint that publishes a `relayPublicKey` (the `hermes_relay_requests` model). This forces the §5 fork.
- **`knowledge_repos`:** Mac holds the key, but the GitHub webhook server is a third reader that must equality-match → cannot seal that field.

---

### 4. RECOMMENDED FIX (SOTA, minimal-drift) — reuse existing primitives

Existing primitives to reuse (do not invent new ones):
- **`CloudVaultCrypto`** (`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`): `sealText`→`CloudVaultSealedText` (124), `sealBlob`→`CloudVaultBlobEnvelope` (137), `sealPayload`/`sealedPayloadDictionary` (161/189). Server validator: `requireCloudVaultBlobEnvelope` (used at `encryptedSearch.ts:368`).
- **`HermesRelayCrypto.sealToBase64`** ECIES `p256-hkdf-sha256-aesgcm` (`HermesRelayCrypto.swift:99`) — the relay-endpoint model used by `hermes_relay_requests`.

**Fix 4a — `project_memory_snapshots` (SEAL; clean, no key gap):**
- `AgentLens/.../SessionLogSyncService.swift:591-602`: drop `"projectDisplayName"` from the cleartext payload; fold it into the already-sealed `sealedSnapshot` blob (it's serialized into the snapshot via `Self.jsonData(snapshot)` at line 586 — confirm `ProjectMemorySnapshot` already carries `projectDisplayName`, so it is **already inside the sealed body**; the top-level field is pure duplication). Replace the doc key: stop using project-name-derived `projectSlug` as the human-readable handle; keep `projectSlug` only if it is already an opaque hash — **verify**: if `projectSlug` is a slug of the project name it is itself a leak and must become a vault-keyed HMAC (reuse the `knowledgeMemory.ts` `slugHmac`/`dedupHashVersion` pattern, B-SEC-2).
- `functions/src/callables/encryptedSearch.ts:348,373,431,477`: remove `projectDisplayName` from the stored doc and from `getEncrypted…`/list responses; if a display label is needed in UI, it comes from the unsealed snapshot client-side. Update `ProjectMemorySnapshotDoc` (`functions/src/types/legacy.ts:1019-1020`).
- Rules: add a dedicated `match /users/{userId}/project_memory_snapshots/{projectSlug}` block (currently absent) with `hasOnly([...non-plaintext...])` rejecting `projectDisplayName` — mirroring the session-log manifest guard. (Note: it's server-written today, so the rule documents intent + future client writes.)

**Fix 4b — `knowledge_repos` (HONEST LABEL, no seal):**
- No code change to the writer (`repoFullName` must stay readable for webhook routing).
- Registry honesty: the `pensieve` domain (registry line 73) currently lists `knowledge_repos` under an `end_to_end` domain whose `deviceOnly` claims "source paths" are device-only. **`repoFullName` is server-readable.** Move `knowledge_repos` out of the `pensieve` E2E `firestorePaths`, OR add a `NOTE:` caveat to the summary and add the repo full name to `serverSees`. Cleanest: keep the vectors/manifests E2E, and add `knowledge_repos` to a `server_readable`-tier home (or `provider_accounts`-style connection metadata) with `serverSees: ["repo full name (webhook routing)", "install id", "source slug"]`.

**Fix 4c — Hosted chat gateway:** decided by §5 fork. Recommended option = **B (ECIES relay-endpoint seal)** reusing `HermesRelayCrypto` + a published `relayPublicKey` on the gateway client doc, mirroring `relayRequestWrite`. Then registry line 116 ("sealed per their own domains") becomes true.

**Fix 4d — make registry line 116 honest:** `packages/data-domains/registry.json:115-117` — the `connected_devices` domain lists ALL `hermes_gateway_*` collections and claims `deviceOnly: ["relayed payload contents (sealed per their own domains)"]`. Today that's false for gateway bodies. Either (B) seal them and the line becomes true, or (A) split gateway message/event/attachment **text** into `serverSees` and rewrite `deviceOnly`.

---

### 5. PRODUCT FORK — Hosted Chat Gateway

The right gateway fix depends on a product decision not derivable from code: **what is a gateway client?**

- **Option A — Honest "server-readable relay" label.** Accept that the hosted chat gateway carries plaintext (a thin bearer-token client e.g. an SMS/Slack/iMessage bridge can't hold a vault key). Then: change registry `connected_devices` (`registry.json:115-117`) so gateway message/event/attachment **text + senderDisplayName + fileName** appear in `serverSees`, not `deviceOnly`; rewrite website `privacy.astro:131-133` ("Hermes relay … never sees plaintext") to scope that claim to the **relay** path only and add a gateway caveat. *Consequence:* honest, zero engineering on the gateway, but the marketing "never sees plaintext" headline narrows.
- **Option B — Seal the gateway (recommended).** Upgrade the gateway client to an ECIES relay endpoint: at pair-approval (`hermesGateway.ts:742-789`) require the client to publish a `relayPublicKey`; change `handleMessageSend`/`enqueueHermesGatewayEvent` to accept only `payloadCiphertext`+`wrappedKey` (reuse `HermesRelayCrypto`, `relayEncryption == "p256-hkdf-sha256-aesgcm"`, exactly like `relayRequestWrite`); store sealed; `serializeHermesGatewayEvent` returns ciphertext. *Consequence:* registry line 116 + website "never sees plaintext" become **true**; every gateway client (and any external bridge) must implement the ECIES handshake — a real client-side lift and a wire-format break (bump `HERMES_GATEWAY_SCHEMA_VERSION`).

**Decision needed from Alberto:** Is the hosted chat gateway a "bring-any-bearer-token bridge" (→ A) or "first-class trusted relay endpoint" (→ B)?

---

### 6. BLAST RADIUS — change in lockstep

**Generator / regen (byte-locked):** after any `registry.json` edit you MUST run `node packages/data-domains/codegen.mjs` (regenerates `packages/data-domains/gen/{domains.ts,DataDomains.swift,DataDomains.kt}` **and** `website/src/data/trust.generated.ts`), then `cd android && ./gradlew :app:syncGeneratedSources` to copy `gen/DataDomains.kt` → `android/app/src/main/java/com/openburnbar/data/domains/DataDomains.kt`. Byte-lock tests that fail otherwise: `packages/data-domains/registry.test.mjs` lines 48-54 (gen on disk), 62-85 (android copy), 109-117 (website trust), plus the honesty assertions 128-151. `driftcheck.mjs` requires every new rules collection to be covered (it already covers the gateway/media/knowledge collections via `connected_devices`/`media`/`pensieve`/`session_logs`).

**Registry honesty tests to extend (`registry.test.mjs`):** add an assertion that any domain listing `hermes_gateway_messages`/`_events`/`_attachments` either is not `end_to_end` (Option A) or has a sealed claim (Option B); add a `project_memory_snapshots → no server-readable project text` assertion; add a `knowledge_repos is server_readable / has webhook caveat` assertion.

**Scanner upgrades — `scripts/privacy/scan-chat-cloud-plaintext.mjs` (node-only, keep):**
1. Add assertions for the currently-ignored surfaces: `project_memory_snapshots` (no top-level `projectDisplayName`; doc-id/slug is HMAC, not project-name slug), `hermes_gateway_messages/_events/_attachments` (Option A: registry tier label; Option B: rules require `payloadCiphertext`+`wrappedKey`+`relayEncryption` and reject `text`/`senderDisplayName`/`fileName`), `knowledge_repos` (registry caveat present), `media_*` (manifest `hasOnly()` excludes plaintext filenames).
2. Add a **semantic `hasOnly()` check**: for each sensitive rules helper (`relayRequestWrite`, `relayChunkWrite`, `validMobileAssistantChatMirror`, `validCliSessionMirror`, `validConversationMirror`, `validCliAgentMissionRequest`, gateway writers if Option B, `project_memory_snapshots` block) assert the section contains `request.resource.data.keys().hasOnly([` — not merely that a denylist `hasAny`/`!("x" in …)` substring exists. (Current `assertRulesRejectFields` only checks `hasAny`.) This closes the "allowlist drift" gap.

**Scrubber upgrades — `scripts/privacy/scrub-chat-cloud-plaintext.mjs`:** add to `COLLECTIONS`/sub-walks: `hermes_gateway_messages` (`text`,`threadId`,`replyToEventId`), `hermes_gateway_events` (`text`,`senderDisplayName`,`threadId`), `hermes_gateway_attachments` (`fileName`), `hermes_relay_requests`+`/chunks` legacy plaintext (`path`,`sessionId`,`body`,`error`,`data`,`text`), `pi_agent_relay_requests`+`/chunks` (same), `text_snippets` (legacy plaintext snippet body), `project_memory_snapshots` (`projectDisplayName`).
**Migration story (not a manual dry-run):** ship an **idempotent backfill** Cloud Function (callable or scheduled) that, per uid, deletes the listed legacy plaintext fields AND, for sealable surfaces (project memory), triggers a **rules-forced re-upload** by stamping `needsReseal=true`/bumping a `resealEpoch` watermark the native client checks on next sync (the device re-seals + overwrites). Gate destructive deletes behind "sealed copy exists" (don't delete `projectDisplayName` unless `sealedSnapshot` present). For gateway under Option B, bump `HERMES_GATEWAY_SCHEMA_VERSION` and let rules reject legacy schema so old plaintext docs are unreadable/expired by TTL.

**Docs (lockstep):**
- `docs/PROVIDERS.md` (gateway/relay rows ~lines 25-30, 74-75, 131): clarify hosted **chat gateway** vs **relay** plaintext posture per the chosen option.
- `docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md` (lines 36-101): state `project_memory_snapshots` holds no top-level `projectDisplayName`/slug-of-name; note `knowledge_repos.repoFullName` is the one server-readable Pensieve field (webhook routing).
- `website/src/pages/privacy.astro:131-133` (relay claim) and `:314-318` (relay E2E claim): scope the "never sees plaintext" claim to the relay path; under Option A add a gateway caveat, under Option B leave as-is once sealed. Trust-domain copy at `:7,166` is generated from `trust.generated.ts` — driven by `registry.json`, regenerated by codegen.

**Clients (Option B only):** every gateway client + external bridge implements the ECIES handshake; native gateway poll/read sites under `AgentLens/Views/Chat/*` and `HermesRelayHostService.swift` must decrypt. **Option A requires no client code.**

**Generated-file note:** never hand-edit `gen/*`, `android/.../DataDomains.kt`, or `website/src/data/trust.generated.ts` — codegen + gradle sync only, or the byte-lock tests fail red.