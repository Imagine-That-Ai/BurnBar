# Two-device validation — F2 / F7 / F10 phone-control protection layers

The crypto, wire contract, and fail-closed/fail-open behavior are proven by
automated tests on every surface (core `swift test`, Mac/iOS xcodebuild, Android
`:app`/`:iroh-relay`, functions vitest, the adapter unittest, and frozen
cross-language KATs). The **one thing automation cannot cover** is a live phone
⇄ Mac session over a real relay with a real biometric. This runbook makes that
pass a scripted ~25-minute checklist with exact pass/fail signals, not a vague
"try it and see."

All three protection flags ship **default-ON** (the strong protocol IS the
launch protocol). So the primary validation is *"the default path works end to
end,"* and the secondary is *"the operator kill switch disengages it."*

**Cross-language wire parity — verified statically (2026-06-10).** The new wire
types (`HermesRealtimeRelayControlSealKeyEnvelope`,
`HermesRealtimeRelaySealedMediaFramePosition`) and the new parent-payload fields
(`controlSealKey`, `sealedFrameBase64`, `mediaSealKey`, `sealedFramePosition`)
have **byte-identical field names** between the Swift and Kotlin models, with no
Kotlin `@SerialName` overrides (so kotlinx-serialization keys == Swift
synthesized-Codable keys). Combined with the frozen cross-language KATs on the
seal primitives and the byte-exact AAD assertions, iOS↔Mac and Android↔Mac share
one wire contract — so a §2/§3 pass on one phone OS is strong evidence for the
other. Physical validation is confirming the *live relay + biometric*, not the
protocol.

## Flags (Firebase Remote Config — `burnbar` project)

| Key | Finding | Default | Role |
|---|---|---|---|
| `computer_use_phone_control_secure_enclave_key` | F2 | ON | hardware (SE/StrongBox) signing key |
| `computer_use_control_seal_enabled` | F10 | ON | sealed control frames |
| `computer_use_media_frame_aead_enabled` | F7 | ON | sealed screen-share frames |
| `computer_use_phone_control_attestation_required` | F2 attest | OFF | *rejection* rule — leave OFF until §6 |

> The flags default ON via a source-aware read: with no Remote Config value set,
> the in-app default is ON; **any** value you set in the console wins. To test
> the kill switch you set a key to `false`; to test the default you simply leave
> it unset.

## Devices

- 1 Mac running the OpenBurnBar **direct-download** build (the sandboxed Mac App
  Store build cannot synthesize input — Accessibility is unavailable there; use
  the notarized direct build for control validation).
- 1 iPhone **with Face ID / Touch ID enrolled** (the SE step-up needs a real
  biometric) signed into the same account.
- 1 Android phone **API ≥ 30 with a biometric enrolled** (below API 30 the app
  deliberately uses the legacy key — see §5).
- Both phones paired to the Mac (Hermes Remote Relay enabled, an
  `iroh_pairing` record exists).

## Log capture

- **Mac:** `log stream --predicate 'subsystem == "com.openburnbar.app"' --info`
  (or Console.app filtered to `com.openburnbar.app`). The E2E proof events also
  land in the in-app Computer Use audit timeline.
- **iOS:** Console.app attached to the device, filter `com.openburnbar.mobile`.
- **Android:** `adb logcat | grep -iE "ControlSeal|MediaSeal|control_seal|media_seal|RemoteConfig"`.

---

## 1. F2 — hardware key + biometric step-up (iPhone → Mac)

1. Fresh-install or re-pair the iPhone so it mints a key under the default-ON
   flag. In Firestore, open
   `users/{uid}/iroh_pairing/{connId}/controllers/{peerNodeId}`.
   - **PASS:** `signingKeyKind == "se-p256"`, `publicKeyBase64` decodes to **65
     bytes** (X9.63, `0x04…`), and `peerNodeId` starts `ios-se-`.
   - FAIL: `signingKeyKind` absent / `ed25519` on a biometric-enrolled device.
2. From the phone, drive a **non-sensitive** action (a tap/scroll on the
   mirrored Mac). It should execute with no biometric prompt.
3. From the phone, request a **sensitive** capability grant (preset that
   includes `shell` or `desktop_system_input`).
   - **PASS:** the phone presents a Face ID / Touch ID prompt at **signing
     time**, and the Mac executes only after it succeeds.
   - **PASS:** the Mac accepts the grant with **no** separate "local-auth proof"
     demand (the SE signature *is* the proof — `validateLocalAuthProofIfNeeded`
     short-circuits for `se-p256`).
   - FAIL: sensitive action runs with no biometric, OR the Mac rejects a
     valid SE grant.
4. **Revocation:** revoke the device from the Mac. Confirm the controller record
   **and** the agent-grant authority are deleted atomically and a revocation
   receipt (`receiptId`) is written; a subsequent intent from that peer is
   denied (`peer_revoked`).

## 2. F10 — sealed control frames (phone → Mac)

1. Start a mirror **with control** (CLI/agent-watch). On the Mac log:
   - **PASS:** `mac_control_seal_established peerNodeId=… connectionId=…`.
2. Send a clipboard-paste or keystroke from the phone.
   - **PASS:** the action executes, and on the wire the `control.*` frame's
     payload carries only `streamClass` + `sealedFrameBase64` (no plaintext
     `inputIntent`/`clipboardRequest`). Easiest check: it works AND the Mac
     logged `mac_control_seal_established` for this connection.
   - FAIL signals (any of these means a frame was dropped fail-closed):
     `control_seal_no_session`, `control_seal_open_failed`,
     `mac_control_seal_establish_failed` in the Mac log/timeline.
3. **Fail-open sanity:** there is no negative to force here in normal use — if
   establishment had failed, control would silently fall back to the legacy
   (iroh-transport-only) lane and still work. That is by design (defense in
   depth on top of the transport seal). Confirm control simply works.

## 3. F7 — sealed screen-share frames (Mac → phone)

1. Start a screen-share mirror. On the Mac log:
   - **PASS:** `media_seal_established connectionID=…`.
   - FAIL: `media_seal_establish_failed` (then frames fall back to plaintext —
     mirror still shows, but the F7 layer didn't engage; investigate the pinned
     relay-sender-key lookup).
2. Confirm the mirror renders normally (sealed frames open on the phone after
   chunk reassembly). A wrong/forged frame is dropped, so a *broken* image with
   the seal "working" would itself be a failure — **PASS is a clean live image.**

## 4. Kill-switch validation (must work on BOTH platforms)

1. In the Firebase console set `computer_use_control_seal_enabled = false`,
   publish.
2. iPhone: force-quit + relaunch (lands the fetch). Android: relaunch (the new
   `RemoteConfigBootstrap.activate()` fetch lands; allow up to the 1-hour
   minimum-fetch interval, or clear app data to force an immediate fetch).
3. Start a control session.
   - **PASS:** the Mac no longer logs `mac_control_seal_established`; control
     still works (legacy lane). The kill switch disengaged the layer.
   - FAIL (Android regression guard): if Android still seals after `false` is
     published and a fetch window has elapsed, `RemoteConfigBootstrap` is not
     landing the value — the kill switch is inert (the exact bug fixed in the
     audit pass; re-verify it shipped).
4. Repeat for `computer_use_media_frame_aead_enabled` and
   `computer_use_phone_control_secure_enclave_key`. **Re-set all three to unset
   (or true) when done** so the secure default is restored.

## 5. Android API < 30 (legacy-key correctness)

On an Android device with **API 26–29**:
- **PASS:** the controller record publishes `ed25519` / `android-phone-…`
  (NOT `se-p256`) even with the SE flag ON, and a sensitive action requires the
  explicit local-auth proof. This proves the API-30 guard
  (`PhoneControlSecureEnclaveKeystore.mintIdentity` refuses below R) — an
  API-29 SE key would be PIN-unlockable, so it must not advertise `se-p256`.

## 6. Attestation ramp (do LAST, post-launch)

Only after §1–§5 pass on real fleet telemetry showing every active controller
sends `attestationHashBlake3`: set
`computer_use_phone_control_attestation_required = true`. This is a *rejection*
rule — flipping it early denies any controller that isn't attesting (now both
iOS and Android attach a digest, but confirm via telemetry first).

---

## Sign-off

| Check | Platform | Result |
|---|---|---|
| §1 SE key + biometric step-up | iPhone | ☐ |
| §1 atomic revoke + receipt | iPhone | ☐ |
| §2 control seal established + works | iPhone/Android | ☐ |
| §3 media seal established + clean mirror | iPhone/Android | ☐ |
| §4 kill switch disengages (both platforms) | iPhone **and** Android | ☐ |
| §5 API<30 uses legacy + forces proof | Android 26–29 | ☐ |
| §6 attestation ramp | post-launch | ☐ (deferred) |

When §1–§5 are checked, the protection layers are field-validated and the
remaining launch gate is only operational (push the hermes-agent fork branch to
origin so CI can fetch the now-cleared pin — see
`third_party/hermes-agent/manifest.json` `remainingOperational`).
