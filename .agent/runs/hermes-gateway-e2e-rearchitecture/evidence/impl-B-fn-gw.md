All my `legacy.ts` edits are confined to the gateway types (`@@` hunks at lines 589-687 are all within the `Firestore: hermes_gateway_*` section) — exactly my ownership scope. Everything is complete, type-clean, lint-clean (no new warnings), and fully tested.

## CHANGELOG

### `functions/src/hermesGateway.ts` (owned)
- **Version bumps:** `HERMES_GATEWAY_SCHEMA_VERSION` 1→**2**, `HERMES_GATEWAY_PROTOCOL_VERSION` 1→**2**.
- **New constants:** `HERMES_GATEWAY_RELAY_ENCRYPTION = "p256-hkdf-sha256-aesgcm"`, `HERMES_GATEWAY_RELAY_PUBLIC_KEY_BYTES = 65`, `HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64 = 900000`, `HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64 = 4096`, `HERMES_GATEWAY_GRACE_WINDOW_CUTOFF = "2026-09-01T00:00:00.000Z"`.
- **New functions:** `isWithinGatewayGraceWindow(now)`, `gatewayPlaintextWriteAllowed(relayCapable, now)` (relay-capable ⇒ always seal; legacy ⇒ plaintext allowed only pre-cutoff), `isGatewayRelayPublicKeyB64(raw)` (validates base64 X9.63 65B/0x04 P-256 key), `requireGatewayRelayEnvelope(raw, field)` (throws `HttpsError`; mirrors `requireSealedText` — algorithm const, keyVersion 1..100, base64 + size caps), `sanitizeGatewayRelayEnvelope(raw)` (non-throwing read-side shape check), plus refactor helpers `hasValidOptionalRelayFields`, `hasValidAttachmentManifestTail`.
- **New type:** `GatewayRelayEnvelopeDoc { payloadCiphertext, wrappedKey, relayEncryption, relayKeyVersion }`.
- **`HermesGatewayClientDoc`:** added `agentRelayPublicKey/agentRelayKeyVersion/agentRelayEncryption`, `phoneRelayPublicKey/phoneRelayKeyVersion/phoneRelayEncryption`, `relayCapable?`. `HermesGatewayEventDoc.text` now optional + added `relayEnvelope?`; `HermesGatewayMessageDoc` added `relayEnvelope?`; `HermesGatewayAttachmentManifestDoc.fileName` now optional + added `relayEnvelope?`.
- **`serializeHermesGatewayEvent`:** passes `relayEnvelope` through verbatim, tolerates missing `text` (sealed schema-2), keeps LEGACY plaintext fallback (schema-1), rejects docs with neither.
- **`isHermesGatewayClientDoc` / `isHermesGatewayAttachmentManifestDoc`:** tolerate the new optional relay/sealed fields.
- **`publicClientView`:** surfaces both relay public keys + `relayCapable` so each peer can seal immediately (private keys never echoed).

### `functions/src/callables/hermesGateway.ts` (owned)
- **New helpers:** `parseRelayPublicKey(body, fields, throwError)` (validates a pubkey trio, surface-agnostic error), `resolveGatewayWriteBody(rawEnvelope, rawText, client, surface)` (seal-vs-plaintext gate: envelope wins; plaintext only for non-relay-capable client in grace window with `hermes_gateway.plaintext_body_deprecated` logInfo; else throws `ciphertext_required`), `assertLegacyAttachmentContentType(...)` (extracted to keep finalize complexity at its pre-existing baseline of 30).
- **`handleDeviceStart`:** accepts+validates+stores `agentRelayPublicKey/agentRelayKeyVersion/agentRelayEncryption` on the device-session doc; rejects unsealed pairing post-cutoff (`unsealed_pairing_unsupported`).
- **`handleDevicePoll`:** approved branch echoes `phoneRelayPublicKey/phoneRelayKeyVersion/phoneRelayEncryption` to the agent.
- **`approveHermesGatewayDeviceGrant`:** accepts the phone's relay pubkey (`phoneRelayPublicKey/...`), carries the agent pubkey from the session onto the client doc, computes+stores `relayCapable` (true iff both keys present), persists phone pubkey on the session (for poll echo), rejects unsealed pairing post-cutoff, echoes agent pubkey via `publicClientView`.
- **`handleRuntimeStatus`:** re-publishes the agent relay pubkey; flips `relayCapable` true once both keys on record.
- **`handleMessageSend`:** requires `relayEnvelope` (drops plaintext `text` past grace), writes sealed body, keeps `empty_message` guard for attachment-only sends.
- **`enqueueHermesGatewayEvent`:** input adds `relayEnvelope`; seals `{text,senderDisplayName,threadId}` path — rejects plaintext text/senderDisplayName/threadId once sealed (`ciphertext_required`), drops them from the stored doc, keeps `model_switch` cleartext `/model <id>` + cleartext `modelId`.
- **`handleAttachmentInit`:** requires `relayEnvelope` (sealed `fileName`), drops plaintext `fileName` field, **drops the `/${fileName}` segment from `storagePath`**, sets opaque `application/octet-stream` for sealed uploads. **`handleAttachmentFinalize`:** path-prefix check accepts the bare `{attachmentId}` object name; skips content-type match/sniff for sealed (ciphertext) uploads, keeping the sha256 as the ciphertext integrity gate.

### `functions/src/types/legacy.ts` (owned — gateway types only)
- Mirrored: added `GatewayRelayEnvelopeDoc`; added the 6 relay-pubkey fields + `relayCapable?` to `HermesGatewayClientDoc`; `HermesGatewayEventDoc.text`→optional + `relayEnvelope?`; `HermesGatewayMessageDoc` + `relayEnvelope?`; `HermesGatewayAttachmentManifestDoc.fileName`→optional + `relayEnvelope?`.

### Tests
- **`functions/src/__tests__/hermesGatewaySealedEvent.test.ts` (NEW, owned):** callable test invoking `enqueueHermesGatewayEvent.run(...)` over an in-memory Firestore double — asserts (1) a sealed `relayEnvelope` is forwarded verbatim and the stored doc carries NO `text`/`senderDisplayName`/`threadId` (deep leaf-walk), (2) a relay-capable client sending plaintext is rejected `ciphertext_required` with nothing written, (3) a malformed envelope is rejected, (4) `model_switch` stays cleartext. 4 tests, all pass.
- **`functions/src/__tests__/hermesGateway.test.ts` (owned):** added helper coverage — version bumps, `isGatewayRelayPublicKeyB64` (accept/reject shapes), `requireGatewayRelayEnvelope` (all reject paths), `serializeHermesGatewayEvent` sealed pass-through + legacy fallback, `publicClientView` relay-key surfacing, grace-window logic. 19 tests, all pass.

### Verification
- `tsc --noEmit`: **exit 0** (no type errors anywhere). `eslint` on all owned files: **0 errors**; remaining warnings (2 `max-lines`, 1 `handleAttachmentFinalize` complexity 30) are **pre-existing** (verified against `HEAD` — finalize was 30 before my edits). Full functions suite: **228 passed / 4 skipped**.

### Deviations / notes
- `requireGatewayRelayEnvelope` throws `HttpsError("invalid-argument")` (not a `GatewayHttpError`); the `burnBarHermesGateway` HTTP wrapper already maps `HttpsError`→400, so both the callable and HTTP surfaces reject identically — no behavior gap.
- `clients.displayName` left server-readable (per CONTRACT §"low sev, noted").

### Cross-stream dependencies (not my files)
- **B-ios-gw:** phone must pass `phoneRelayPublicKey` into `approveHermesGatewayDeviceGrant`, read the echoed `agentRelayPublicKey`, seal events via `relayEnvelope`, and keep the legacy plaintext read fallback in `HermesGatewayMessageRecord` decode.
- **F-adapter/F-crypto (fork):** agent must publish `agentRelayPublicKey` at `device/start` + `/runtime`, seal message/attachment bodies, and open events — byte-exact to the FIXED `relayEnvelope`/AAD contract.
- **B-honesty:** reclassify `hermes_gateway_events/messages/attachments` dataExport tier server_readable→end_to_end (`dataExport.ts` is owned by B-honesty; this stream only enabled it).