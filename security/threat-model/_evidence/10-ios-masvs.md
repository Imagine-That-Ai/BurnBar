# 10 — iOS / iPadOS + Keyboard + Widget Security (MASVS / MASTG)

Domain: `ios-app-masvs`. Auditor-grade evidence package for the OpenBurnBar mobile
client, the custom keyboard extension, and the WidgetKit extension. The **code is
the source of truth**; doc prose was used only for orientation. Every line ref below
was read directly with rg/Read.

Scope of targets:
- `OpenBurnBarMobile/` (SwiftUI app — Firebase, CloudVault, ComputerUse, Hermes/Mercury)
- `OpenBurnBarKeyboard/` (custom keyboard extension, `RequestsOpenAccess = true`)
- `OpenBurnBarWidget/` (WidgetKit extension + Live Activities)
- Shared code in `OpenBurnBarCore/` that the extensions link (App Group, TextExpansion, CloudVaultCrypto)

---

## Components & files reviewed

App / config:
- `OpenBurnBarMobile/Info.plist` (URL schemes `burnbar`, Google reversed client id; usage strings; `UIBackgroundModes: audio`; `ITSAppUsesNonExemptEncryption=false`)
- `OpenBurnBarMobile/Resources/OpenBurnBarMobile.entitlements` (data protection, App Attest, keychain group, App Group, iCloud, applesignin, aps-environment)
- `OpenBurnBarKeyboard/Info.plist` (`RequestsOpenAccess=true`), `OpenBurnBarKeyboard/Resources/OpenBurnBarKeyboard.entitlements` (App Group only)
- `OpenBurnBarWidget/Info.plist`, `OpenBurnBarWidget/Resources/OpenBurnBarWidget.entitlements` (App Group only)
- `project.yml` (target wiring; keyboard/widget are `app-extension`, no data-protection/keychain entitlement)

Key/crypto/storage:
- `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift`
- `OpenBurnBarMobile/Services/iOSDeviceKeypair.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` (`CloudVaultKeyStore` lines 1374-1435)
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultDeviceKeypair.swift`
- `OpenBurnBarMobile/Services/ComputerUse/PhoneControlSender.swift` (Secure Enclave biometry-gated key)
- `OpenBurnBarMobile/Services/MobileChatHistoryStore.swift` (local chat at rest)
- `OpenBurnBarMobile/App/MobileDataProtectionBootstrap.swift`
- `OpenBurnBarMobile/Models/DataVaultStore.swift`

App Group / extensions data flow:
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/BurnBarWidgetSnapshot.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/InsightVerdictWidgetSnapshot.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionSnapshotStore.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionInbox.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionUsageStore.swift`
- `OpenBurnBarKeyboard/KeyboardViewController.swift`, `KeyboardView.swift`, `PredictiveTextService.swift`, `SpellCheckService.swift`, `SwipeTypingEngine.swift`

Deep links / IPC / clipboard / capture:
- `OpenBurnBarMobile/App/OpenBurnBarMobileApp.swift` (`handleDeepLink`, `HermesGatewayPairingDeepLink`)
- `OpenBurnBarMobile/Services/AgentReplyNotificationService.swift` (push content, FCM/APNs token)
- `OpenBurnBarMobile/Views/ComputerUse/ScreenPrivacyGuard.swift` (+ usage: `InlineAgentMirrorView.swift:222`, `AgentWatchView.swift:92`)
- `OpenBurnBarMobile/Views/Media/MercuryLiveSheet.swift` (remote clipboard paste/grab)
- `OpenBurnBarMobile/Services/SmartHubDisplaySettingsAdapter.swift:106`, `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift:2101`, `OpenBurnBarMobile/Views/SmartHub/NestHubSettingsCard.swift:584` (clipboard copy)

---

## Controls present

| Control | file:line — symbol | Strength | Note |
|---|---|---|---|
| App-wide file data protection floor | `OpenBurnBarMobile/Resources/OpenBurnBarMobile.entitlements:15-16` — `com.apple.developer.default-data-protection = NSFileProtectionComplete` | strong | App-container files default to Complete. Does NOT extend to App Group container (see Gaps). |
| Per-write Complete protection for chat at rest | `MobileChatHistoryStore.swift:442-448` — `writeProtected` (`.completeFileProtection` + `setAttributes(.protectionKey:.complete)` + backup exclusion) | strong | Closes the launch-sweep gap for mid-session writes; correct `.complete` choice. |
| Launch-time protection sweep + backup exclusion | `MobileDataProtectionBootstrap.swift:7-23` — `apply()` over AppSupport/Documents/Caches/tmp | moderate | Bounded by `maxRecursiveItems = 2_000` (line 4) and only sweeps app-container dirs, not the App Group container. |
| CloudVault key in Keychain, device-only | `CloudVaultCrypto.swift:1416,1425` — `CloudVaultKeyStore.saveKey` `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | strong | 32-byte symmetric vault key; not synced to iCloud Keychain; not biometry-gated. |
| Escrow device private key in Keychain, device-only | `iOSDeviceKeypair.swift:108,147` — `saveToKeychain`/`saveOldKey` `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | strong | P-256 KeyAgreement key; ECIES wrap of vault key to trusted devices. |
| Per-action biometry-gated Secure Enclave signing key (ComputerUse F2 step-up) | `PhoneControlSender.swift:783-799` — `mintSecureEnclaveKey` (`.privateKeyUsage, .biometryCurrentSet`, SE-backed) | strong | OS refuses to sign without live biometric; falls back to software Ed25519 only when SE/biometry unavailable (`:754-768`). |
| Escrow public-key immutability (TOFU pinning) | `MobileCloudVaultKeyAccess.swift:59-115` — `MobileEscrowPublicKeyPublisher.publishIfNeeded` rejects conflicting re-publish | moderate | Prevents silent public-key swap for a given `deviceId_keyVersion`; enforcement also depends on server rules (out of iOS scope). |
| Trusted-device chain verification before wrapping vault key | `MobileCloudVaultKeyAccess.swift:388-422` — only wraps to `trustState == trusted` after `MobileCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice` | moderate | New devices land `pending` (`:371`); a pending device cannot receive a wrapped key. |
| App-switcher snapshot + screen-recording mask for Mac mirror | `ScreenPrivacyGuard.swift:28-48,84-87` — `MobileScreenPrivacyState.shouldMask` (`scenePhase != .active || isCaptured`) | moderate | Applied only to the two mirror surfaces (`InlineAgentMirrorView.swift:222`, `AgentWatchView.swift:92`); not app-wide. |
| Deep-link handler does not auto-execute prompts | `OpenBurnBarMobileApp.swift:160-204` — `handleDeepLink` navigates only; `prompt` query values explicitly ignored on public URL path (`:162-163,184`) | moderate | Prompt-bearing deep links navigate but never auto-submit; AppIntents may stash (in-process). |
| Pairing deep link is origin-restricted | `OpenBurnBarMobileApp.swift:49-62` — `HermesGatewayPairingDeepLink.pairingCode` only accepts `https://burnbar.ai/hermes/connect` or specific `burnbar://` hosts | moderate | Code is posted to a notification; not auto-consumed without UI. |
| Push preview flattened to plain text (no markdown injection into banner) | `AgentReplyNotificationService.swift:41,175` — `HermesAtomParser.plainText(...)` | weak | Mitigates markdown/format, not plaintext sensitivity (see Threats). |
| Keyboard has no network egress despite Open Access | `OpenBurnBarKeyboard/*` — no `URLSession`/Firestore/HTTP in target (rg over `OpenBurnBarKeyboard/*.swift`) | strong | Keystrokes/`documentContextBeforeInput` are processed locally only; not exfiltrated. |
| Keyboard does not persist typed text for learning | `PredictiveTextService.swift`, `SwipeTypingEngine.swift`, `SpellCheckService.swift` — no `UserDefaults`/`write`/file persistence of input | strong | Predictions come from static dictionaries; only snippet usage counts are written. |
| Extensions cannot read app keychain group | `OpenBurnBarKeyboard/Resources/OpenBurnBarKeyboard.entitlements`, `OpenBurnBarWidget/Resources/OpenBurnBarWidget.entitlements` — App Group only, no `keychain-access-groups` | strong | Keyboard/widget cannot read vault/escrow/SE keys (different bundle ids, no shared keychain group). |
| Remote clipboard request size-bounded | `MercuryLiveSheet.swift:1887,1900-1903` — `maxBytes = 65_536` enforced before paste-to-Mac | moderate | DoS/oversend guard; does not restrict clipboard content sensitivity. |
| GoogleService-Info hardening in CI | `project.yml:537-549` — build phase fails non-Debug builds if certain keys present in `GoogleService-Info.plist` | moderate | API-key/identifier scrubbing intent; deployed plist content UNKNOWN from repo. |

---

## Claims verified against code

| Claim | Status | Evidence | Note |
|---|---|---|---|
| "RR-14: default every file the app writes to NSFileProtectionComplete" (entitlement comment) | Partial | `OpenBurnBarMobile.entitlements:10-16` | True for the **app** container only. App Group container files (snippets, widget snapshot, keyboard inbox/usage) are NOT covered — the entitlement is per-process and the keyboard/widget have no data-protection entitlement. |
| "chat store additionally sets `.completeFileProtection` per write" | Defensible | `MobileChatHistoryStore.swift:442-448` | Verified; `.complete` and backup exclusion at write time. Chat lives in app container (`applicationSupportDirectory/OpenBurnBar`, `:321-329`), not App Group. |
| "Vault keys stored in Keychain WhenUnlockedThisDeviceOnly" (threat-model:418) | Defensible | `CloudVaultCrypto.swift:1416,1425`; `iOSDeviceKeypair.swift:108,147`; `CloudVaultDeviceKeypair.swift:73` | All key material uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. |
| "Device unlock state is trustworthy; Keychain protects keys from other local users/processes" (threat-model:152) | Partial | `iOSDeviceKeypair.swift:108` | Holds against other apps. But there is **no app-level biometric/passcode re-auth gate** at launch (`AuthGateView.swift` has no `LAContext`), so on a lost-but-unlocked device the keys are usable by anyone holding the phone. |
| Deep links do not auto-run agent prompts | Defensible | `OpenBurnBarMobileApp.swift:162-163,184` | Public URL path ignores `prompt`; navigation only. |
| Screen mirror is protected from screenshots/recording (iOS FLAG_SECURE analogue) | Partial | `ScreenPrivacyGuard.swift:28-48`; applied at `InlineAgentMirrorView.swift:222`, `AgentWatchView.swift:92` | Only the Mac-mirror surfaces are masked. Chat transcripts, provider secret entry, recovery key entry, and dashboards are NOT screenshot/record-masked. |
| Keyboard with Open Access does not log/exfiltrate keystrokes | Defensible | no network/persistence in `OpenBurnBarKeyboard/*` (rg) | Open Access is used for App Group snippet sharing + haptics, not telemetry. |
| Push notification previews do not leak agent plaintext | Partial | `AgentReplyNotificationService.swift:39-41,175,188-189,196-199` | Today previews are "generic" (comment `:39-40`), but the payload pipeline carries `preview`/`title` as plaintext in APNs `userInfo` and `UNNotificationContent.body`; if the server ever sends real reply text it lands on the lock screen and in `userInfo` unencrypted. Not E2E for the notification surface. |
| Trusted-device enrollment gates vault-key access | Defensible | `MobileCloudVaultKeyAccess.swift:360-422` | Wrapping only to `trusted` devices after chain verification; new device defaults `pending`. |
| `ITSAppUsesNonExemptEncryption=false` | NotDefensible (as compliance posture, not a security control) | `Info.plist:44-45` | App ships strong crypto (AES-GCM, ECIES, Secure Enclave). The `false` export flag is an attestation that custom/non-standard crypto isn't used; arguably fine under the Apple-provided-crypto exemption, but flagged for legal/export review — it is not a security control and should not be read as one. |

---

## Threats

| id | title | category (STRIDE/LINDDUN/Agentic + framework) | severity | component | attack path | existing mitigation | gap | residual risk |
|---|---|---|---|---|---|---|---|---|
| T-IOS-01 | App Group container data not file-protected | Information Disclosure / LINDDUN Disclosure (MASVS-STORAGE-1) | Medium | `BurnBarWidgetSnapshot.swift:86-92`, `TextExpansionSnapshotStore.swift:12-21`, `TextExpansionInbox.swift:29-38`, `TextExpansionUsageStore.swift` | App Group files written via plain `Data.write(.atomic)` with no protection class. The data-protection entitlement is per-process and present only on the main app; the keyboard/widget extensions (which also write here) have no data-protection entitlement, and the writers never set `.protectionKey`. On a stolen device imaged while locked, or via an iTunes/Finder backup that captures the shared container, the contents are readable. | Main-app entitlement floor for app container; chat uses `.complete`. | App Group container is outside the entitlement floor and no explicit protection class is set on these writes. | Disclosure of text-expansion snippet bodies (can contain arbitrary user-authored text / boilerplate that may include addresses, internal phrasing), keyboard inbox snippets, and cost/model aggregates (`heroTotalCost`, `topModels`). Not key material. |
| T-IOS-02 | No app-level biometric / passcode re-auth gate | Spoofing / Elevation (MASVS-AUTH-1) | High | `AuthGateView.swift` (no `LAContext` at launch), `OpenBurnBarMobileApp.swift` | A lost-but-unlocked iPhone (or one unlocked by a coercer/family member) gives full app access: send agent prompts, control the paired Mac (`MercuryLiveSheet`/AgentWatch), read chat history, trigger budget/panic actions. Firebase session persists; vault/escrow keys are `WhenUnlocked` so they decrypt freely while the device is unlocked. | Per-sensitive-ComputerUse-action step-up exists for some flows (`PhoneControlSender.swift:783`, `MobileAgentPermissionGrantController.swift:112-116`). | No global Face ID / passcode gate to enter the app or view chat / vault data; only specific ComputerUse presets require local auth. | Full takeover of a high-trust endpoint on an unlocked, unattended device. ComputerUse step-up reduces (not eliminates) blast radius. |
| T-IOS-03 | Mirror privacy mask is surface-scoped, not app-wide | Information Disclosure (MASVS-PLATFORM-3 / screenshot+recording) | Medium | `ScreenPrivacyGuard.swift`; applied only at `InlineAgentMirrorView.swift:222`, `AgentWatchView.swift:92` | Screen recording / AirPlay / app-switcher snapshot captures any non-masked screen: chat transcripts, provider API-key `SecureField`s after reveal, the Data Vault recovery-key entry (`DataVaultRecoveryView.swift:48`), dashboards. Only the live Mac mirror is masked. | `screenPrivacyGuard()` on the two mirror views; `SecureField` hides typed password input. | No app-wide app-switcher snapshot cover; sensitive non-mirror screens are recordable/screenshotable. | Leak of agent conversation content, provider credentials, and recovery keys via screen recording or the recents snapshot. |
| T-IOS-04 | Push preview/title carried as plaintext in APNs payload | Information Disclosure (MASVS-NETWORK / data minimization) | Medium | `AgentReplyNotificationService.swift:36-45,188-206,260` | Remote pushes (and locally-presented ones) put `title`/`preview` directly in `UNNotificationContent.body` and `userInfo`. APNs payloads are visible to Apple's push infra and rendered on the lock screen. Comment says previews are "generic today" — there is no code-level guarantee they stay generic; a server change makes real agent text leak to the lock screen / APNs. | Markdown flattening (`:41,175`); device fan-out respects notification auth state. | No enforced redaction or `mutable-content` + Notification Service Extension to fetch/decrypt the real body client-side. | Sensitive agent reply text could surface on lock screen and transit APNs in cleartext; breaks the otherwise E2E/at-rest sealing story (`AgentNotificationReplySealer` seals the *reply*, not the inbound preview). |
| T-IOS-05 | Sensitive material copied to system pasteboard without expiry/local-only | Information Disclosure (MASVS-STORAGE-2 / pasteboard) | Medium | `SmartHubDisplaySettingsAdapter.swift:106` (voiceRefreshURL), `HermesSettingsView.swift:2101` (gateway command), `NestHubSettingsCard.swift:584` (curl snippet), `MercuryLiveSheet.swift:1969` (Mac clipboard grab) | Values written to `UIPasteboard.general.string` with no `expirationDate` and no `localOnly` option. These can include bootstrap/refresh URLs and `curl` snippets that may carry bearer tokens, plus arbitrary Mac clipboard contents. Any other app reading the pasteboard, and Universal Clipboard (Handoff) to other Apple devices, can read them; they persist until overwritten. | Size bound on Mac-clipboard paste-to-Mac (`:1900-1903`). | No `UIPasteboard` `expirationDate`/`localOnly` options; no pasteboard clearing. | Token/URL/clipboard disclosure to other apps and Handoff-paired devices; persistence beyond intended use. |
| T-IOS-06 | App Group is a confused-deputy surface between app and extensions | Tampering / Spoofing (MASVS-PLATFORM-1 / IPC) | Low | `TextExpansionInbox.swift:42-71`, `KeyboardViewController.swift:76-95,183` | Keyboard writes snippets into the shared snapshot + inbox; the app drains and pushes them through cloud sync (`OpenBurnBarMobileApp.swift:126`). A compromised/replaced extension (or any process with the App Group entitlement, e.g. a malicious sibling build) could plant snippets or poison usage ranking that the app later trusts and uploads. Darwin notification trigger (`KeyboardViewController.swift:24-59`) is also unauthenticated. | Snippet validation in `TextExpansionKeyboardComposer.makeSnippet` (`TextExpansionInbox.swift:113-152`); dedup by id. | No integrity/authenticity check on App Group payloads; trust boundary is implicit. | Limited — snippet bodies are user-facing text, but they can be auto-synced to cloud and re-expanded on other surfaces (stored-text injection into outbound agent messages). |
| T-IOS-07 | Deep-link / URL-scheme handler routes attacker-influenced params | Tampering / Spoofing (MASVS-PLATFORM-2 / deep links) | Low | `OpenBurnBarMobileApp.swift:137-208` | `burnbar://` scheme is unverified (no associated-domains/Universal-Link verification for the custom scheme). Any app/web page can invoke `burnbar://assistants?runtime=...&threadId=...` and drive navigation, stash a pending thread, or trigger `ShowAgentWatch`. `threadId` flows into a Firestore-scoped view unsanitized; `runtime` is enum-validated. | Prompts ignored on public path (`:162-163,184`); pairing code origin-restricted (`:49-62`); host switch is allow-listed. | Custom scheme is not cryptographically attributable to a caller; navigation/UI-state can be driven by any origin. | Phishing/UI-redress and forced navigation; no auto-execution, so impact is bounded to social-engineering into a thread/screen. |
| T-IOS-08 | Keyboard "Open Access" expands attack surface and is a privacy signal | Information Disclosure / Spoofing (MASVS-PLATFORM-1) | Low | `OpenBurnBarKeyboard/Info.plist:31-32` (`RequestsOpenAccess=true`) | Open Access grants the keyboard App Group + (potentially) network capability. Today there is no network code, but a future/poisoned build could exfiltrate keystrokes once the user has granted Full Access in Settings. Users granting Full Access to a keyboard that types into password/banking fields is the classic iOS keylogger risk. | No network egress in current code; no input persistence (verified). | Open Access is requested broadly; no in-product justification gating to App-Group-only behavior (which does not strictly require Open Access for reading the shared container in all cases). | Latent keylogger surface if a malicious update ships; current build is benign. |
| T-IOS-09 | Vault/escrow keys not biometry- or SE-bound | Tampering / Information Disclosure (MASVS-CRYPTO-2 / key protection) | Medium | `CloudVaultCrypto.swift:1414-1429`, `iOSDeviceKeypair.swift:101-116` | The 32-byte vault key and the P-256 escrow private key are stored as raw `kSecValueData` Keychain items (`WhenUnlockedThisDeviceOnly`) — not Secure-Enclave-wrapped and not `.biometryCurrentSet`-gated. Any code path running as the app while the device is unlocked (incl. T-IOS-02 lost-unlocked, or a future app-internal RCE) can read the plaintext vault key and decrypt the whole CloudVault. | Device-only accessibility; ComputerUse uses a separate SE+biometry proof credential (`PhoneControlSender.swift:786`), proving the capability exists. | Vault and escrow secrets are not SE-wrapped or biometric-gated despite an implemented pattern elsewhere in the same app. | Whole-vault decryption from app context on an unlocked device; weaker than the ComputerUse key's protection. |
| T-IOS-10 | No jailbreak / runtime-integrity assumption stated or enforced | Tampering (MASVS-RESILIENCE-1) | Info | (absence) — no jailbreak/`cydia`/integrity checks in `OpenBurnBarMobile/` | On a jailbroken device, Keychain ACLs and file protection can be bypassed; all of the above keys/data become reachable. | None on-device (App Attest is server-side anti-fraud, not local integrity). | No jailbreak detection / anti-tamper (acceptable for a local-first app, but the threat model should state the assumption explicitly). | Determined attacker with a jailbroken target gets full local access; this is an accepted-risk class, but currently undocumented as such for iOS. |
| T-IOS-11 | Launch-time protection sweep is bounded and may miss files | Information Disclosure (MASVS-STORAGE-1) | Low | `MobileDataProtectionBootstrap.swift:4,41-46` | The recursive sweep stops after `maxRecursiveItems = 2_000`; a large Caches/Documents tree leaves later items at default (still `Complete` via entitlement, but the explicit sweep + backup-exclusion intent is skipped). Third-party SDK caches (Firebase/Firestore on-disk persistence) may land outside the swept set's intent. | Entitlement floor still applies to app container; chat writes are self-protected. | Sweep is best-effort and capped; Firestore local cache protection class not explicitly asserted in code. | Marginal — entitlement keeps app-container files at Complete; residual is backup-exclusion gaps and any SDK files written to the App Group. |

---

## Gaps / missing controls

- **App Group container has no file-protection class set on its writers** (`BurnBarWidgetSnapshot.swift:90-91`, `TextExpansionSnapshotStore.swift:20`, `TextExpansionInbox.swift:37`, `TextExpansionUsageStore.swift`). The entitlement floor does not extend across the process boundary into the shared container; the keyboard/widget extensions have no data-protection entitlement at all. Add `.completeUnlessOpen`/`.complete` per write (or set `.protectionKey` on the shared dir) — note the keyboard may need `.completeUntilFirstUserAuthentication`/`.completeUnlessOpen` to read on a locked device, so choose deliberately.
- **No app-wide local-auth (Face ID / passcode) gate** to enter the app or reveal chat/vault data (`AuthGateView.swift`). Only some ComputerUse presets step up.
- **No app-wide app-switcher snapshot blur** and **no screenshot/recording mask on chat, credential entry, or recovery-key screens** — `screenPrivacyGuard()` is only on the Mac mirror.
- **CloudVault secret and escrow private key are not Secure-Enclave-wrapped or biometry-gated** even though the SE+biometry pattern is already implemented for the ComputerUse proof credential.
- **Pasteboard writes lack `expirationDate` / `localOnly`** and are never cleared (4 sites).
- **No Notification Service Extension** to fetch/decrypt push bodies client-side; reliance on "previews are generic today" is a process control, not a code control.
- **No integrity/authenticity binding on App Group payloads** crossing the keyboard↔app boundary (confused-deputy into cloud sync).
- **Custom `burnbar://` scheme is not Universal-Link-verified** and any origin can drive navigation/UI state.
- **No documented iOS jailbreak/runtime-integrity assumption** in the threat model.

---

## Overclaims (doc/name implies more than code)

- **Entitlement comment "default every file the app writes to NSFileProtectionComplete ... this entitlement is the floor for everything else"** (`OpenBurnBarMobile.entitlements:10-16`) — overclaims coverage: the App Group container and the extension processes are *not* covered by this per-process entitlement, and those shared-container writers set no protection class. "Everything else" is really "everything the **main app process** writes inside its **own** container."
- **`ScreenPrivacyGuard` doc: "the iOS analogue of Android's FLAG_SECURE"** (`ScreenPrivacyGuard.swift:5-19`) — FLAG_SECURE on Android is a window-wide flag; here it is a per-view opt-in applied to only two screens. The name implies broader/stronger coverage than the call sites provide.
- **`MobileDataProtectionBootstrap` naming implies comprehensive at-rest protection** but is a capped (`2_000`) best-effort launch sweep that does not touch the App Group container.
- **Threat-model row "App <-> Keychain ... device unlock state is trustworthy"** (`threat-model:152`) reads as an enforced control, but there is no app-side enforcement of *re-auth* — it leans entirely on the OS lock and a persistent Firebase session (see T-IOS-02).
- **`ITSAppUsesNonExemptEncryption=false`** (`Info.plist:44-45`) sits next to genuinely strong crypto; it should not be read as "no meaningful encryption" — it's an export-compliance attestation, flagged for legal review rather than a security property.

---

## Crypto / protocol notes (iOS-relevant)

- Escrow ECIES (`iOSDeviceKeypair.swift:38-79`): ephemeral-static P-256 ECDH → HKDF-SHA256 (empty salt, `sharedInfo = "OpenBurnBar-Escrow-v1"`) → AES-256-GCM. Wire format `ephemeral_pub(65) || AES.GCM.combined`. Empty HKDF salt is acceptable for ephemeral-static ECIES (the ephemeral pubkey provides freshness) but the `sharedInfo` is the only domain separation; no explicit recipient binding in the AAD. Conservative note: this is fine for key-wrapping but relies on the ephemeral key uniqueness for IND-CPA.
- Vault key = 32-byte symmetric AES-GCM key (`CloudVaultKeyStore`), wrapped per-device with the above ECIES (`MobileCloudVaultKeyAccess.swift:402-405`). Vault-key identity verified by `vaultKeyID` comparison on unwrap (`:290-296`) — mismatch throws, preventing acceptance of a key for a different vault state.
- ComputerUse authority key: Secure-Enclave P-256, `.biometryCurrentSet + .privateKeyUsage` (`PhoneControlSender.swift:786`) — strongest local key. Demonstrates the app *can* SE/biometry-gate, which is why T-IOS-09 (vault/escrow keys NOT so gated) is a defensible gap rather than a platform limitation.
- Notification reply sealing uses CloudVault AAD context binding `uid/collection/docID/field` (`AgentReplyNotificationService.swift:82-90`) — good AEAD binding for the *outbound reply*, but does not protect the *inbound preview* (T-IOS-04).

---

## Open questions / UNKNOWN (deployed evidence would resolve)

- **What does the production push fan-out actually put in `preview`/`title`?** Resolve by inspecting the deployed Cloud Function that builds the APNs payload and a captured production push. Code only proves the client renders whatever it receives.
- **Is the App Group container included in device backups / what protection class does iOS assign by default there?** Resolve by inspecting an encrypted backup or an on-device file-protection dump of `group.com.openburnbar.app`.
- **Does the deployed `GoogleService-Info.plist` contain any sensitive keys?** The CI guard (`project.yml:537-549`) scrubs some keys for non-Debug, but the committed plist content and the release build's plist were not inspected here.
- **Does the keyboard's "Full Access" actually get requested/granted in production, and is `RequestsOpenAccess` strictly necessary** for the current App-Group-only behavior? Resolve by testing snippet read on a build with Open Access denied.
- **Firestore on-disk cache protection class** (Firebase SDK manages its own files) — not asserted in app code; resolve by inspecting the SDK's file attributes on device.
- **Server-side enforcement of escrow public-key immutability and trusted-device trust state** — the iOS client enforces TOFU locally, but the authoritative check is in `firestore.rules` / callables (out of this domain's scope).
