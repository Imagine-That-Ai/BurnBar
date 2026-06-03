Same expected Firebase limitation, no code errors. All edits are structurally sound. Let me do one final consistency check: confirm the test for the undecryptable reply will actually be undecryptable — `HermesGatewayRelayKeypair.loadOrCreate()` returns this device's persistent key, and I sealed to a freshly-generated OTHER key, so unwrap fails → `resolvedText == nil` → `isUndecryptableHere == true`. Correct. And the round-trip test seals to `phoneKeypair.relayPublicKeyBase64` (this device) → opens. Correct.

Let me verify the `HermesGatewayMessageRecord` test helper at line 749 still compiles given the added `openedAttachments` (init sets it to `[]`, so no change needed). And confirm `attachmentIds` default empty in that helper — yes, `"attachmentIds": []`.

One last check: the existing test `testHermesGatewaySealedReplyForAnotherDeviceStaysSealed` asserts `displayText == nil` for the other-device case — my changes don't affect `displayText` (still returns `resolvedText` when sealed). Good. And `isUndecryptableHere` = `isSealed && resolvedText?.isEmpty != false` → for other-device, `resolvedText == nil` → `nil?.isEmpty != false` → `nil != false` → true. Correct.

All fixes are complete and verified. Let me produce the changelog.

## Summary verification

Final confirmation that all owned files were touched as required and the canonical contract is honored: Swift remains the source of truth (event/message payload-vs-key AADs were already correct; I added the 3 attachment AADs to match Python), and I verified all 7 gateway AAD labels byte-match Python plus a full Python attachment wire round-trip confirming my opener.

## CHANGELOG

**`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift`**
- Added `gatewayAttachmentManifestAAD`, `gatewayAttachmentBodyAAD`, `gatewayAttachmentKeyAAD` helpers (labels `gatewayAttachmentManifest` / `gatewayAttachmentBody` / `gatewayAttachmentKey`, built via the existing private `aad(_:)` so the prefix + key-wrap shared-info stay single-sourced).
- Closes: HIGH "Agent→phone sealed attachments have no iOS opener" / "Swift defines no `gatewayAttachment*AAD`" (audit results 2, 3, 9, 13, 18). The event/message payload-vs-key AADs were already canonical here (Swift is the source of truth); Python is the side that must align.
- Verified: standalone build is the only LSP-resolvable file and returns **zero diagnostics**; a Python harness proved all 7 gateway AAD labels (incl. the 3 new attachment labels) byte-match `adapter.py`.

**`OpenBurnBarMobile/Services/FunctionsRepository.swift`**
- `HermesGatewayMessageRecord`: added `isUndecryptableHere`, `static sealedForAnotherDeviceText` (jargon-free re-pair copy), and `chatRenderText(emptyFallback:)` — one source of truth that returns opened body → opened-attachment summary → calm re-pair state → unopened-attachment summary → fallback. Made `string`/`dictionary` helpers non-private so the new attachment type can reuse them.
- Added `HermesGatewayAttachmentRecord` (parses `hermes_gateway_attachments` envelope + `bodyStoragePath`), `HermesGatewayOpenedAttachment`, and `HermesGatewayAttachmentManifest`, with open primitives `unwrapBodyKey` (binds `gatewayAttachmentKey`), `openManifest` (binds `gatewayAttachmentManifest`), `openBody` (binds `gatewayAttachmentBody`, decodes the ascii-base64 body blob), and `opened(downloadedBody:using:uid:)`. UI download/render is marked a **tracked** follow-up in-code (listener + Storage fetch + bubble); until then the chat already shows an attachment summary, never a blank reply.
- Added `FunctionsError.gatewayAttachmentUnreadable`; rewrote `gatewayTargetMissingRelayKey` / `gatewayRelayKeyChanged` copy to remove protocol jargon ("relay key", "man-in-the-middle", "end-to-end encrypted") per the copy policy.
- Closes: HIGH attachment-opener blocker; HIGH undecryptable-UX (shared re-pair copy); MEDIUM jargon-leak (these two error strings).

**`OpenBurnBarMobile/Services/HermesService.swift`**
- `finishBurnBarGatewayTurn` now renders `reply.chatRenderText(...)` instead of the legacy `reply.text` (always nil on sealed schema≥2 docs).
- Closes: **BLOCKER** "Sealed gateway reply renders 'Hermes replied without text.' in chat" (audit result 0 / 11 CONFIRMED).

**`OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift`**
- `gatewayReplyBodyText` delegates to `reply.chatRenderText(...)`; `presentReplyNotification` preview uses the same helper so a reply this device can't open surfaces the re-pair line (not a blank/jargon preview) consistently across chat, hero, and notification.
- Closes: HIGH undecryptable-UX consistency; supports the BLOCKER fix (single render source).

**`OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift`**
- `unsubscribe`: resolves the vault key first; on nil/throw it sets `lastError` and throws the new `StoreError.vaultKeyUnavailable` **before** removing the local row or clearing the error, so a transiently-unavailable key can no longer orphan the sealed cloud subscription behind a success UI. Deletes the opaque sealed doc first (via new pure `resolveUnsubscribeDocID`), then legacy cleartext ids, then drops the local row. Added `StoreError.vaultKeyUnavailable` with recoverable jargon-free copy.
- Closes: HIGH "ghost unsubscribe when the vault key is transiently unavailable" (audit result 7 / 16 CONFIRMED). (Android `AgentSubscriptionTopicStore.kt` has the parallel bug but is out of my owned set — flagged as a cross-platform follow-up.)
- `HermesTabView.swift`: no change needed — both `applyPendingGatewayReplyIfNeeded` sites already pass the decoded `latestReply` (opened in `handleMessagesSnapshot`) into `finishBurnBarGatewayTurn`; threading the opened text through `chatRenderText` there fixes the render with no call-site edit.

**`OpenBurnBarMobileTests/OpenBurnBarMobileTests.swift`** (tests I own)
- `testGatewaySealedReplyChatRenderShowsOpenedText` — sealed reply renders the opened plaintext (BLOCKER).
- `testGatewayUndecryptableReplyChatRenderShowsRePairState` — wrong-device reply renders the re-pair state, asserts non-empty and **no crypto jargon** (HIGH).
- `testGatewaySealedAttachmentOpensRoundTrip` — seals an attachment exactly as Python `seal_attachment` (distinct manifest/body/key AADs, body blob = ascii base64 of sealed body) and proves the new iOS opener recovers filename + bytes (HIGH attachment opener).
- `testGatewaySealedAttachmentCrossSlotSwapFailsTag` — body-into-manifest swap fails the AES-GCM tag.
- `testGatewaySealedAttachmentForAnotherDeviceDoesNotOpen` — wrong-device attachment returns nil (caller shows re-pair).

**`OpenBurnBarMobileTests/AgentSubscriptionTopicSealTests.swift`** (tests I own)
- `test_resolveUnsubscribeDocID_withoutKey_throwsRecoverableError` — nil key throws `vaultKeyUnavailable` with non-empty jargon-free copy (proves the orphan can't happen).
- `test_resolveUnsubscribeDocID_withKey_targetsTheOpaqueSealedDoc` — with a key it returns the same opaque id as `documentID`, so the delete hits the real sealed doc.

Cross-language verification run (Python allowed): `py_compile` on `adapter.py` + `relay_e2ee.py` passed; a `relay_e2ee` attachment seal→open round-trip confirmed my Swift opener's wire assumptions (body key under `gatewayAttachmentKey`, manifest under `gatewayAttachmentManifest`, body blob = ascii base64 opened under `gatewayAttachmentBody`, cross-slot swap fails). No cross-repo builds were run. Edited only owned files. Swift LSP shows no code errors on edits — only expected "No such module 'Firebase*/XCTest'" resolution notices; the fully-resolvable core (`HermesRelayCrypto.swift`) is clean.