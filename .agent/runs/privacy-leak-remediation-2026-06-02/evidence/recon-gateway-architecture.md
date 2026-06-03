I have the complete, definitive picture. Writing the design brief.

# RECON: Hermes Gateway (P0) — DESIGN BRIEF

## 1. DATA FLOW (writer → readers, file:line)

The gateway is a **store-and-forward bus between TWO participant classes**:
- **Participant A — external agent** (a third-party adapter, NOT a BurnBar app): `tools/hermes-platform-burnbar/adapter.py`. Authenticates via device-code + opaque bearer token (`hgw_…`). Talks the HTTP API `https://api.burnbar.ai/v1/hermes-gateway` (`adapter.py:36`).
- **Participant B — the user's own BurnBar phone** (OpenBurnBarMobile), signed in with Firebase Auth, reads/writes Firestore directly.

Per collection:

**`hermes_gateway_events`** (carries `text`, `senderDisplayName`, `senderId`, `threadId`, `modelId`)
- WRITER: `enqueueHermesGatewayEvent` callable, `functions/src/callables/hermesGateway.ts:982-999`. Plaintext fields written: `text` (`:993`), `senderDisplayName` (`:992`), `senderId` (`:991`), `threadId` (`:990`). Called by phone: `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift:2120, 2195` via `FunctionsRepository.enqueueHermesGatewayEvent` (`FunctionsRepository.swift:1005-1035`).
- READER 1 (external agent): `GET /events` → `handleEvents` (`hermesGateway.ts:414-450`) serializes the doc verbatim incl. `text`/`senderDisplayName` (`hermesGateway.ts:438` → `serializeHermesGatewayEvent`, `functions/src/hermesGateway.ts:294-325`, copies `text` `:319`, `senderDisplayName` `:318`) and streams it SSE/JSON. The Python agent consumes it: `adapter.py:341` (`/events`), reads `raw.get("text")` (`:359`), `raw.get("senderDisplayName")` (`:369`).
- READER 2: none on the BurnBar phone (phone only listens to `hermes_gateway_messages`, below).

**`hermes_gateway_messages`** (carries `text`, attachment refs — these are the AGENT's replies)
- WRITER: external agent, `POST /messages` → `handleMessageSend` (`hermesGateway.ts:452-480`), plaintext `text` `:457,473`. Agent calls it: `adapter.py:206-213` (`json={"text": …}`).
- READER (phone): direct Firestore snapshot listener on `hermes_gateway_messages` ordered by `createdAt` desc — `HermesSettingsView.swift:2003-2012`; decoded by `HermesGatewayMessageRecord(documentID:data:)` reading **plaintext** `data["text"]` (`FunctionsRepository.swift:354`) and renders it (`HermesSettingsView.swift:483 gatewayReplyHero`, `:2235-2273`).

**`hermes_gateway_attachments`** (manifest carries `fileName`; bytes live in Storage)
- WRITER: `handleAttachmentInit` (`hermesGateway.ts:531-568`) writes plaintext `fileName` (`:535,557`) and `storagePath` derived from it (`:544`); `handleAttachmentFinalize` (`:570-657`) hashes the **plaintext** Storage object (`sha256ForStorageFile`, `:163-176`, `:634`). Bytes uploaded by agent via v4 signed write URL (`:546-551`) — `adapter.py:135-190` (`_init_attachment`/`_upload_attachment`).
- READER: the phone downloads bytes from Storage; manifest `fileName` read on both ends.

**`hermes_gateway_typing`** — `handleTyping` (`:482-500`), no private text (just `threadId`).
**`hermes_gateway_state/cursors`** — `enqueueHermesGatewayEvent` transaction (`:972-981`), monotonic `eventSequence` only, no private text.
**`hermes_gateway_clients`** / `hermes_gateway_destinations` — `displayName` is a user-chosen client label (e.g. "Hermes Agent") + `runtimeModelOptions`. Lower sensitivity but `displayName` is user text.

`firestore.rules:1955-1989`: all gateway collections are `read: if ownsUserNamespace; write: if false` — i.e. **only the owner UID reads via Firestore; all writes go through privileged Functions / signed URLs.** The external agent never gets Firestore creds — it only sees what `/events` returns.

## 2. SERVER-READ REQUIREMENT — definitive: NO

**No Cloud Function reads `.text`, `.fileName`, `senderDisplayName`, or attachment bytes for any purpose other than store/forward and integrity.** Proof:
- `handleMessageSend` (`:457-477`): `boundedTrimmedString` length-clamps `text`, then `.set(doc)`. No LLM call, no indexing, no budget keyed on content.
- `handleEvents` (`:414-450`): reads docs, copies verbatim, returns. Filtering is by `sequence`/`destinationId`/`targetClientId` (`:425-441`), never by body.
- `enqueueHermesGatewayEvent` (`:926-1004`): clamps `text`, monotonic sequence, `.set`. The only `text` synthesis is `/model …` for `model_switch` (`:954-955`) — derived from `modelId`, not user prose.
- Attachments: server only computes `sha256` over bytes for **integrity** (`:634`) and validates content-type/size (`:619-632`). It never feeds bytes to a model or returns body content from a Function (download is a client→Storage signed read).
- Entitlement/budget gate (`assertActiveHermesGatewayEntitlement`, `:232-242`) is keyed on **entitlement docs**, never message content.
- `dataExport.ts:110-131` and `panic.ts` enumerate these collections by path for export/wipe — they move blobs, they don't parse `.text`.

This is **pure store-and-forward**. The server-read requirement that would force plaintext does **not** exist. Sealing is therefore *cryptographically possible without losing any server feature.*

## 3. VAULT-KEY AVAILABILITY — the decisive constraint

| Participant | Holds Cloud Vault key? | Evidence |
|---|---|---|
| Cloud Function (server) | No (by design) | n/a |
| BurnBar phone (Participant B) | **Yes** — `MobileCloudVaultKeyAccess` (it already opens sealed conversations/snippets/session-logs) | `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift` |
| External agent `adapter.py` (Participant A) | **No** — authenticates only with a device-secret + bearer token; never receives the vault key, never does ECIES | `adapter.py:597,639-640` (device flow); `_send_message`/`_create_attachments` send raw `text`/bytes (`:206-213`, `:135-190`) |

**This is the crux.** Unlike the already-sealed surfaces (conversations, cli_sessions, etc.) whose *both* endpoints are first-party BurnBar apps that hold the vault key, the Hermes Gateway's far end is a **deliberately keyless third-party adapter**. A vault key cannot be handed to an arbitrary external CLI agent without breaking the vault's threat model (the server would have to wrap it to a device it cannot attest). **Therefore full vault-key E2E sealing of `text`/`fileName` across the gateway is impossible for the external-agent leg as currently designed.**

## 4. SEALED-SIBLING COMPARISON — `hermes_relay_requests` does NOT reuse the vault key

The sealed sibling uses a **different, separate primitive** from the Cloud Vault:
- `hermes_relay_requests` is sealed with **`HermesRelayCrypto`** + a **per-connection ECDH relay keypair** (`HermesRelayKeyStore`), *not* the Cloud Vault key: `HermesRelayHostService.swift:631-641` (`relayKeyStore.privateKey()`, `unwrapSymmetricKey`, `openBase64`), fields `payloadCiphertext`/`wrappedKey`/`relayEncryption`/`relayKeyVersion` (`legacy.ts:547-550`). The phone wraps an AES key to the Mac's *relay public key* it fetched from `hermes_connections` (`HermesRelayHostService.swift:275-278, 345-347`).
- This works because **both endpoints are first-party** (phone ↔ Mac host) and the Mac publishes a relay public key the phone trusts.

**Reusability verdict:** The gateway's two legs split:
- **Phone ↔ phone-readable replies (`hermes_gateway_messages` agent replies the phone renders):** could be sealed, but the *agent* writes them and has no key.
- **Phone → agent (`hermes_gateway_events.text`):** the *agent* must read them and has no key.

So the relay's exact approach (ECIES-wrap to a published per-connection key) **cannot be lifted unchanged**, because the external agent neither publishes nor holds any such key. It *could* be adapted only if we make the external adapter a key-holding participant (see Product Fork).

## 5. PRODUCT FORK (this fix is NOT derivable from code alone)

The gateway's whole product purpose (`HermesGatewayPromo.astro`, console domain) is **"connect your agent to messengers you already use"** — i.e. bridge to external/third-party agents over an open bearer-token HTTP API. Whether plaintext is acceptable is a **product decision**:

**Option A — Honest server-readable label (minimal, ship-now).**
Accept that the external-agent leg is server-readable by design (the bytes already transit a third-party adapter and the server must hand `text` to a keyless client). Make every surface *say so*. The collections currently sit in the `connected_devices` domain labeled `encryptionTier: "server_readable"` (`dataExport.ts` `connected_devices` block; `domains.ts:268-292`) — **the data-domain label is already honest.** The leak is that **product/UX/marketing imply E2E** and there is **no per-message disclosure**. Fix = labeling + Control-Center copy + remove any E2E claim near the gateway.
- Consequence: zero crypto work, no client breakage, true to the open-bridge product. But "server can read your gateway messages/files" must be surfaced prominently and the gateway must be excluded from any "end-to-end encrypted" marketing.

**Option B — Two-key E2E (seal the phone-readable leg only; honest-label the agent leg).**
Recognize the asymmetry: the phone *does* hold the vault key. Seal the fields **only the phone reads** (`hermes_gateway_messages.text` = the agent's replies) is impossible (agent is the writer, no key). Seal the fields **only the agent reads** (`hermes_gateway_events.text`) is impossible (agent is the reader, no key). **Both private-text legs have a keyless endpoint** → there is *no* subset that becomes E2E without changing the adapter. The *only* way to get real E2E is **Option C**.

**Option C — Make the external adapter a vault participant (full E2E, high cost).**
At pairing (`approveHermesGatewayDeviceGrant`, `hermesGateway.ts:699-794`), ECIES-wrap the Cloud Vault key to a keypair the adapter generates during `device/start` (extend `deviceSecretHash` flow to carry a device public key). Then the adapter seals `text`/`fileName` with AES-256-GCM using the vault key, and the server stores only `CloudVaultBlobEnvelopeDoc` (`legacy.ts:906-913`).
- Consequence: real E2E, reuses the **existing `CloudVaultBlobEnvelopeDoc` / AES-256-GCM** primitive. But it (a) hands the master vault key to an arbitrary third-party Python process — **weakens the vault threat model**, (b) requires shipping vault crypto in `adapter.py` and every future third-party gateway client, (c) breaks all existing adapters until upgraded. This contradicts the "open bridge for any agent" product.

**RECOMMENDATION:** **Option A (honest labeling)** is the SOTA minimal-drift fix and is *correct*, because the gateway is, by design, a bridge to a **keyless third-party agent** that the server must serve plaintext. Pursuing E2E (Option C) would require trusting arbitrary external processes with the vault key — strictly worse for privacy than honestly labeling a clearly-scoped server-readable bridge. The data-domain tier (`server_readable`) is already right; the defect is *missing/contradictory user-facing disclosure*, not missing crypto.

(If Alberto's product intent is "the gateway MUST be E2E," then the honest move is to **retire the open bearer-token adapter** and route gateway traffic through the already-E2E `hermes_relay_requests` path between first-party apps — i.e. fold the gateway into the relay rather than bolt vault crypto onto third parties.)

## 6. BLAST RADIUS (lockstep changes for the recommended Option A)

**No schema/field changes** (this is the low-drift win). Changes are disclosure + guardrails:
- **Server:** none functionally required. Optionally add a `serverReadable: true`/`encryptionTier` echo on responses for client truthfulness — `hermesGateway.ts handleMessageSend/handleEvents`. Confirm `dataExport.ts:104` `connected_devices.encryptionTier` stays `"server_readable"` (it is) so export labeling is honest.
- **Generated data-domains (must stay in sync, all three):** `packages/data-domains/gen/domains.ts:268-292`, `gen/DataDomains.kt`, `gen/DataDomains.swift`, and the hand source `android/.../data/domains/DataDomains.kt:81` — verify the domain carrying `hermes_gateway_*` is `server_readable` and the Control Center renders that tier as "BurnBar can read this." (`AgentLens/Services/DataControlCenterViewModel.swift`, `OpenBurnBarMobile/.../DataVaultStore.swift`, `OpenBurnBarMobile/Views/Control/*`).
- **Mobile UX:** `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift` (`gatewayReplyHero` `:483`, the connect/promo copy) and `HermesTabView.swift` — add a "messages to/from this agent are readable by BurnBar Cloud (not end-to-end encrypted)" disclosure; ensure no E2E lock-icon is shown on gateway threads.
- **Website:** `website/src/components/HermesGatewayPromo.astro` + `website/test/integration/hermes-gateway-promo.test.ts` — scrub any implied E2E/"private"/"secure" language so the bridge is positioned as server-readable; align with `project_website_copy_policy` (benefit-first, safety-forward, no overclaim).
- **Console:** `apps/console/lib/domains.generated.ts` (regenerated) — same tier label.
- **Tests in lockstep:** `functions/src/__tests__/hermesGateway.test.ts` (assert tier/labeling, no E2E), `OpenBurnBarMobileTests/OpenBurnBarMobileTests.swift` (gateway record decoding stays plaintext), `tools/hermes-platform-burnbar/smoke_local.py` (unchanged), website promo test.
- **Docs:** `docs/SOTA_REMEDIATION_PLAN.md` (record gateway as "server-readable by design, honestly labeled" — distinct from the false-E2E-label P0s), `docs/PENSIEVE_CONTROL_CENTER*.md` (gateway tier surfacing), and any "end-to-end" claim in `droid-wiki/` referencing Hermes Gateway must be corrected (it mirrors to mem0).

**Key files for implementers (absolute paths):**
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/hermesGateway.ts` (writers: `:452-480`, `:531-568`, `:926-1004`; readers: `:414-450`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/hermesGateway.ts` (`serializeHermesGatewayEvent:294-325`, field maxes `:16-18`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/types/legacy.ts` (event/message/attachment/blob-envelope shapes `:625-660`, `:906-913`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/FunctionsRepository.swift` (`HermesGatewayMessageRecord:328-372`, callable wrappers `:970-1035`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift` (Firestore reader `:2003-2012`, render `:483, 2235-2273`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/tools/hermes-platform-burnbar/adapter.py` (keyless external agent: `:36, 135-213, 341-460, 597-640`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/CloudSync/HermesRelayHostService.swift` (sealed-sibling pattern, separate relay key: `:619-656`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/firestore.rules` (`:1955-1989`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/dataExport.ts` (`connected_devices` tier `:95-131`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/packages/data-domains/gen/domains.ts` (`:268-301`)

---

## DESIGN BRIEF

1. **Classify the surface honestly: Hermes Gateway is a server-readable store-and-forward bridge to a *keyless third-party agent* (`adapter.py`), not an E2E channel.** Proof: server never reads bodies for logic (`hermesGateway.ts:452-480, 414-450, 926-1004`); the far-end agent holds no vault key and sends/reads plaintext (`adapter.py:206-213, 359, 369, 135-190`). Do **not** attempt vault-key sealing of `text`/`senderDisplayName`/`fileName`/attachment bytes — at least one endpoint of every private-text leg is keyless, so E2E is impossible without re-architecting the adapter.

2. **Keep the schema unchanged.** No new `payloadCiphertext`/envelope fields on `hermes_gateway_events|messages|attachments`. (Sealing would strand the external agent.)

3. **Lock `encryptionTier = "server_readable"`** for the domain carrying all `hermes_gateway_*` collections; verify it across the four generated/source domain files: `functions/src/callables/dataExport.ts:104`, `packages/data-domains/gen/domains.ts`, `gen/DataDomains.kt`, `gen/DataDomains.swift`, and `android/.../data/domains/DataDomains.kt:81`. It is already `server_readable` — assert and freeze it with a test.

4. **Surface the disclosure in every UI that renders gateway content** so the label is *visible*, not just in the data model: `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift` (`:483`, connect copy), `HermesTabView.swift`, and the Data & Privacy Control Center (`DataControlCenterViewModel.swift`, `DataVaultStore.swift`). Remove any E2E lock iconography from gateway threads; show "BurnBar Cloud can read messages and files exchanged with connected agents (not end-to-end encrypted)."

5. **Scrub overclaiming marketing:** `website/src/components/HermesGatewayPromo.astro` + its test, per `project_website_copy_policy` (no "private/secure/E2E" implication for the bridge).

6. **Add guardrail tests in lockstep:** `functions/src/__tests__/hermesGateway.test.ts` (tier = server_readable, no sealing required), `OpenBurnBarMobileTests` (gateway record stays plaintext-decoded), website promo test (no E2E claim).

7. **Record the verdict in docs/mem0:** `docs/SOTA_REMEDIATION_PLAN.md` — mark Hermes Gateway as **"server-readable by design, fix = honest labeling,"** explicitly distinct from the genuine false-E2E-label P0s; correct any `droid-wiki/` page that calls the gateway encrypted (it mirrors to mem0 verbatim).

8. **If product intent is "must be E2E":** the only honest path is to **retire the open bearer-token adapter and route gateway traffic through the already-E2E `hermes_relay_requests` first-party relay** (`HermesRelayHostService.swift:619-656`, `HermesRelayCrypto`/`HermesRelayKeyStore`) rather than handing the Cloud Vault key (`CloudVaultBlobEnvelopeDoc`, `legacy.ts:906-913`) to arbitrary third-party processes. State this fork to Alberto before any crypto work — it is a product decision, not an engineering one.