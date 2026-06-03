# LOCKED CONTRACT — Gateway E2E + 3 tails (Wave 4)

Single source of truth for cross-stream invariants. Full detail per slice is in `evidence/recon-gw-*.md`.
Reuse EXISTING crypto only. Decoders keep a LEGACY plaintext fallback during migration.

## Repos
- BurnBar: `/Users/albertonunez/Documents/Windsurf/BurnBar` (remote Imagine-That-Ai/BurnBar, branch codex/format-functions-callables)
- Hermes fork: `/Users/albertonunez/.hermes/hermes-agent` (remote ajnunezg=Ajnunezg/hermes-agent, branch ajnunezg/burnbar-platform)

## PR plan
- **PR1 → fork**: BurnBar platform addition. Reconcile `plugins/platforms/burnbar/adapter.py` to the canonical 891-line BurnBar-repo copy; polish tests/docs/lint. **NO crypto.** Remove the unrelated `gateway/platforms/api_server.py` change from the branch (separate concern).
- **PR2 → fork**: Gateway E2EE. New `gateway/crypto/relay_e2ee.py` + test + fixture + pyproject `cryptography` extra + adapter sealing. Depends on PR1 (same adapter.py).
- **Companion → BurnBar repo**: server (functions) + iOS + rules + honesty + migration. Ships with PR2.
- **Tails → BurnBar repo**: media-filename, dedup-v0, subscription-cloak, rollback-status.

---
## CRYPTO CONTRACT (byte-exact — the crux). Source of truth: OpenBurnBarCore/.../HermesRelayCrypto.swift
- Algorithm `"p256-hkdf-sha256-aesgcm"`, keyVersion 1. P-256/secp256r1. X9.63 uncompressed pubkeys (65B, 0x04‖X‖Y). Private key = raw 32B big-endian scalar (Python: `ec.derive_private_key(int.from_bytes(raw,'big'), SECP256R1())`).
- ECDH shared secret = raw 32B X-coord. HKDF-SHA256: salt = 32 zero bytes, info = `b"OpenBurnBar-HermesRelay-KeyWrap-v1|" + aad`, len 32.
- AES-256-GCM: 12B nonce, 16B tag. Payload seal `.combined = base64(nonce(12)‖ct‖tag(16))`. Wrapped key = `base64(ephPubX963(65)‖nonce(12)‖ct(32)‖tag(16))` = 125B, [0]==0x04.
- AAD = `"OpenBurnBar-HermesRelay-v1|" + "|".join(parts)`, UTF-8. **keyAAD for wrap, requestAAD for payload, chunkAAD per chunk.**
- Python module home: `gateway/crypto/relay_e2ee.py` (NEW package). API: `generate_private_key()/RelayPrivateKey.from_raw/.raw_representation/.public_key_base64()`, `seal_to_base64`, `open_base64`, `wrap_symmetric_key`, `unwrap_symmetric_key`, `request_aad/key_aad/chunk_aad`, namespace param (also serves PiAgent). Lazy-import cryptography; `cryptography>=46` added to pyproject + uv.lock.
- Interop gate: vendor `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json` → `tests/gateway/fixtures/`; `tests/gateway/test_relay_e2ee.py` opens Swift's wrappedKey/payloadCiphertext/chunkCiphertext + Python round-trip + adversarial (wrong-AAD InvalidTag, 125B/44B shapes, two-wraps-distinct).

## GATEWAY WIRE CONTRACT
Pairing: agent publishes its P-256 pubkey at `device/start` (`agentRelayPublicKey`/`agentRelayKeyVersion`/`agentRelayEncryption`); phone publishes its pubkey at `approveHermesGatewayDeviceGrant` (`relayPublicKey`/...). Both stored on `HermesGatewayClientDoc`. Agent also publishes via `handleRuntimeStatus`. Server returns the peer pubkey to each side (poll/grant return).

Per-doc sealed sub-object `relayEnvelope { payloadCiphertext, wrappedKey, relayEncryption:"p256-hkdf-sha256-aesgcm", relayKeyVersion:int }`:
- `hermes_gateway_events` (phone→agent): seal JSON `{text, senderDisplayName, threadId}`, wrap to **agentRelayPublicKey**, AAD parts `["gatewayEvent", uid, clientId, eventId]`. Drop top-level text/senderDisplayName/threadId. Keep routing: id/sequence/kind/destinationId/targetClientId/senderId/modelId/attachmentIds/createdAt/schemaVersion. (model_switch keeps cleartext modelId.)
- `hermes_gateway_messages` (agent→phone): seal `{text}`, wrap to **phoneRelayPublicKey**, AAD `["gatewayMessage", uid, clientId, messageId]`. Drop top-level text.
- `hermes_gateway_attachments` (agent→phone): seal bytes with per-attachment 32B key (AAD `["gatewayAttachmentBody", uid, clientId, attachmentId]`) before signed-URL upload; manifest `relayEnvelope.payloadCiphertext` = sealed `{fileName, byteCount, contentType}`, `wrappedKey` wraps the body key to phone (AAD `["gatewayAttachmentKey",...]`). Drop plaintext fileName + the fileName segment from storagePath. Server hashes ciphertext for integrity only.
- typing/state unchanged. clients.displayName left server-readable (low sev, noted).
Server validator `requireGatewayRelayEnvelope` (mirror requireSealedText): relayEncryption const, relayKeyVersion 1..100, payloadCiphertext b64 ≤900000, wrappedKey b64 ≤4096. Handlers REJECT plaintext text/senderDisplayName/fileName once sealed/schema≥2.
Bump `HERMES_GATEWAY_SCHEMA_VERSION=2`, `HERMES_GATEWAY_PROTOCOL_VERSION=2`. Grace window: `relayCapable?:bool` on client doc; before cutoff accept plaintext from legacy clients (logInfo deprecation), after cutoff reject. Reads keep legacy plaintext fallback.
Gateway Firestore collections are `write:if false` (server-written) → enforcement is in the CALLABLE/HTTP handlers, not new rule allowlists. Honesty: dataExport tier for events/messages/attachments → end_to_end (was server_readable); clients/destinations/typing/state stay server_readable.

## TAILS
- **media-filename**: NO writer exists today → CREATE the sealing iOS writer (new `OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift`, wired at AppDelegate sink `:59-76`), seal `filename`→`sealedFilename` (CloudVaultCrypto.sealText, MobileCloudVaultKeyAccess.keyForWriting), exact hasOnly key set, single writer-of-record per direction (`allow update:if false`). Flag-day: B-rules DROPS the plaintext-filename branch in firestore.rules (`:2792-2834`) + flips T9 test to assertFails on plaintext. No legacy debt. legacy.ts already sealed-ready. Honesty: registry media domain filename→deviceOnly + scanner coverage.
- **dedup-v0**: floor `dedupHashVersion==1` in knowledgeSearch.ts (`:89-93`) + commit idempotent-skip (knowledgeMemory.ts `:295-299`); bump embeddingModelVersion `"bge-small-en-v1.5"`→`"bge-small-en-v1.5-vault-dedup-v1"` in PensieveVectorCloak.swift `:35` + Node embed.ts EMBEDDING_MODEL_VERSION (identical string); add `purgeLegacyKnowledgeVectors` callable+scheduled in knowledgeMemory.ts (delete dedupHashVersion==0 + retired-model-tag rows via deleteQueryInBatches) registered in index.ts; firestore.indexes.json composite; flip knowledgeMemoryDedupHash.test.ts to assert v0 not served + purged; docs PENSIEVE.md.
- **subscription-cloak**: opaque doc id = vault-keyed HMAC of `agentURI:topicID` (new `CloudVaultCrypto.subscriptionDocID(agentURI:topicID:keyData:)` helper, HKDF label "subscription-topic", mirror pensieveSlugHmac); seal agentURI/topicID→sealedAgentURI/sealedTopicID; keep cadence/consentGivenAt cleartext (order/filter). iOS AgentBrandZoneView.swift (documentID + encode/decode, 4 call sites pass key) + Android AgentSubscriptionTopicStore.kt. Legacy fallback on read. order(by:consentGivenAt) preserved.
- **rollback-status**: RollbackContracts.swift Status → explicit snake_case rawValues (`inFlight="in_flight"`) + add `cancelled` + tolerant `init(from:)` and `init?(wireValue:)` accepting legacy `"inFlight"`. RollbackService.swift:180 uses `Status(wireValue:)`. B-rules adds `cancelled` to firestore.rules:1650 status allowlist.

## STREAM OWNERSHIP (disjoint files)
- **F-crypto** (fork): gateway/crypto/relay_e2ee.py, tests/gateway/test_relay_e2ee.py, tests/gateway/fixtures/HermesRelayWireVector.json, pyproject.toml/uv.lock (cryptography extra).
- **F-adapter** (fork): plugins/platforms/burnbar/adapter.py (reconcile to BurnBar-repo 891-line canonical + add sealing via F-crypto module), tests/gateway/test_burnbar_plugin.py, plugins/platforms/burnbar/README.md. (api_server.py removal handled by orchestrator at PR-prep, not an edit.)
- **B-fn-gw**: functions/src/callables/hermesGateway.ts, functions/src/hermesGateway.ts, functions/src/types/legacy.ts (gateway types only), functions/src/__tests__/hermesGateway*.test.ts.
- **B-ios-gw**: OpenBurnBarMobile/Services/FunctionsRepository.swift, OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift, OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift (NEW), OpenBurnBarCore/.../HermesRelayCrypto.swift (public AAD wrappers only).
- **B-rules**: firestore.rules (gateway comments + media flag-day drop + rollback cancelled), functions/scripts/test-firestore-rules.mjs (T9 media flip + rollback).
- **B-media**: OpenBurnBarMobile/App/AppDelegate.swift, OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift (NEW), OpenBurnBarMobileTests/Media/*.
- **B-dedup**: functions/src/callables/knowledgeMemory.ts, functions/src/callables/knowledgeSearch.ts, functions/src/index.ts, firestore.indexes.json, functions/src/__tests__/knowledgeMemoryDedupHash.test.ts, OpenBurnBarCore/.../PensieveVectorCloak.swift, tools/openburnbar-mcp-remote/src/embed.ts.
- **B-sub**: OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift, android/.../data/square/AgentSubscriptionTopicStore.kt, OpenBurnBarCore/.../CloudVaultCrypto.swift (subscriptionDocID helper).
- **B-rollback**: OpenBurnBarCore/.../Contracts/RollbackContracts.swift, OpenBurnBarMobile/Services/RollbackService.swift.
- **B-honesty**: packages/data-domains/registry.json (+codegen regen), scripts/privacy/scan-chat-cloud-plaintext.mjs, functions/src/callables/dataExport.ts (gateway tier + sealedFilename seal-aware), docs/{PENSIEVE.md,PROVIDERS.md}, website/src/pages/privacy.astro.
Agents EDIT + self-review only. All builds/tests/PRs run centrally (orchestrator).
