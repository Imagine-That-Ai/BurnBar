All correct. `OSStatus` is `Int32`, and `unknownKeychainError(status: Int(status))` converts properly. The pin store is complete and fail-closed.

Let me do a final check: confirm the test file's new tests reference only existing symbols. The `HermesRelayPrivateKey` type is used implicitly through `agentPrivate` (a `HermesRelayPrivateKey` from `generatePrivateKey()`), passed to `unwrapSymmetricKey`. The `rawRepresentation` re-derivation was removed. `XCTUnwrap` and `JSONSerialization` are standard. All good.

Let me verify one last potential issue: the test `testGatewayEventSealPinsAgentKeyThenRefusesChangedKey` uses a `freshPinStore()` that shares the real Keychain — but with unique random `clientId` per test (UUID) and explicit `clearPin` in `defer`, so no cross-test pollution. The `uid` is fixed but namespaced by `uid|clientId`, and clientId is unique. Good.

Let me also confirm `PinResult.mismatch(pinned:)` Equatable comparison in the test works — `XCTAssertEqual(result, .mismatch(pinned: originalKey))` requires `PinResult: Equatable`, which I declared with auto-synthesis. 

All changes are complete and internally consistent. Let me produce the changelog.

## CHANGELOG

**`OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift`**
- Added `HermesGatewayAgentKeyPinStore` (Sendable, Keychain-backed TOFU pin store keyed by `uid|clientId`, `kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). API: `verifyOrPin(agentPublicKeyBase64:uid:clientId:) -> PinResult` (pins on first use, matches identical keys, refuses differing keys), `pinnedKey(uid:clientId:)`, `clearPin(uid:clientId:)`. `PinResult` is `Equatable` with `.allowsSeal` gate; `.mismatch` and `.unknownKeychainError` (Keychain read failure / undecodable pin) both fail closed. Private `PinLoad` enum models the read (since `OSStatus` is not `Error`).
- **Closes Finding 1 (P1 phone-side key pinning):** the phone now pins the agent relay pubkey at first pairing and refuses to seal to any later-advertised different key. Belt-and-suspenders with the server immutability fix.

**`OpenBurnBarMobile/Services/FunctionsRepository.swift`**
- Split the seal logic: `applyGatewayEventSeal` is now a thin `@MainActor` wrapper that resolves `uid` from `Auth` and delegates to a new pure `nonisolated static sealGatewayEventPayload(...:uid:pinStore:)`. The core now runs the TOFU pin check via `HermesGatewayAgentKeyPinStore.verifyOrPin(...).allowsSeal`; a mismatch / unreadable-pin throws `FunctionsError.gatewayRelayKeyChanged` **before** any ciphertext is built (fail-closed — no plaintext or attacker-readable envelope leaves the device). **Closes Finding 1.**
- Fixed the encode side to write the nested `relayEnvelope { payloadCiphertext, wrappedKey, relayEncryption, relayKeyVersion }` (was flat top-level fields), aligning the writer with the decode side and the locked contract (CONTRACT.md §28) — restores byte-correct interop with the agent reader. The byte-exact crypto primitives (AAD, wrap, seal) are unchanged, so `HermesRelayWireVector.json` interop is intact.
- `enqueueHermesGatewayModelSwitch`: on `canSealToAgent` links, seals the model_switch (modelId now rides inside `relayEnvelope.payloadCiphertext` alongside text/senderDisplayName/threadId, no top-level cleartext `modelId`); keeps cleartext `modelId` only for legacy non-`canSealToAgent` links during the grace window (wire byte-identical to the pre-seal model_switch). **Closes Finding 2 (P2 model_switch sealed on send).**
- `FunctionsError`: added `gatewayRelayKeyChanged` (MITM message) and made the enum `Equatable`.

**`OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift`**
- `HermesGatewaySettingsStore`: added `agentKeyPinStore`, `agentRelayKeyChanged(for:)` (pin-vs-advertised check), and `clearAgentKeyPin(clientId:)`. Pre-flight MITM guard added to `sendGatewayMessage` and `switchGatewayModel` (surfaces the "relay key changed — possible man-in-the-middle, re-pair" notice and refuses to send). Pin is cleared on deliberate re-pair (`approve`) and `revoke` so re-pairing re-establishes trust on first use.
- UI surfaces the MITM state: `gatewayReadinessNotice` banner (error style, `exclamationmark.shield.fill`), and the per-client badge color/icon/subtitle ("Relay key changed — re-pair"). **Supports Finding 1.**

**`OpenBurnBarMobileTests/OpenBurnBarMobileTests.swift`**
- Added tests (all use unique random `clientId` + `defer clearPin`, no Keychain cross-talk):
  - `testAgentKeyPinFirstUsePinsAndMatchesSameKey` — first-use pins, same key matches + `allowsSeal`.
  - `testAgentKeyPinMismatchRefusesAndReportsPinnedKey` — differing key → `.mismatch(pinned:)`, not sealable, pin unchanged.
  - `testAgentKeyPinClearReestablishesTrustForRepair` — `clearPin` re-enables first-trust for the rotated key.
  - `testGatewayEventSealPinsAgentKeyThenRefusesChangedKey` — first seal pins + drops top-level plaintext + nests `relayEnvelope`; a changed advertised key throws `FunctionsError.gatewayRelayKeyChanged` and leaves the payload empty (no envelope/text/eventId). **Covers Finding 1.**
  - `testSealedModelSwitchCarriesModelIdInsideEnvelopeAndRoundTrips` — sealed model_switch has no cleartext `modelId`; the agent unwraps the per-event key and opens the payload to recover `modelId`/`threadId`/`senderDisplayName`. **Covers Finding 2.**
- Added helpers `sealableGatewayClient(id:agentPublicKey:)` and `freshPinStore()`.

Note: did not run cross-repo builds per instructions; could not `swiftc`-parse standalone due to FirebaseAuth/SwiftUI/OpenBurnBarCore module dependencies. Edits were self-reviewed for single-definition uniqueness, actor isolation (`nonisolated static` mirrors the existing `decodeHermesGatewayApprovalClientForTesting`), and `Equatable`/`Result`-vs-`OSStatus` correctness. FIX-server must read `modelId` from inside the sealed model_switch envelope for `canSealToAgent` links (cleartext only for legacy).