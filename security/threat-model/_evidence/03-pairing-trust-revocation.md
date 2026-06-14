# 03 — Pairing, Trusted-Device Graph & Revocation (domain: pairing-trust-revocation)

Reviewer note: code is source of truth. Verified against CURRENT commit (2026-06-13). The internal
package (CURE53_REVIEW_PACKAGE_2026-06-12) flagged vault rotation as UNWIRED on revoke (RR-5 / T-ID-4 /
overclaim #7). **That is now REMEDIATED** — see T-PTR-01 evidence. Residual gaps recorded below.

## Components & files reviewed
- `functions/src/callables/computerUseSecurity.ts` — registerEscrowDevice, approveEscrowDeviceTrust, revokeEscrowDeviceTrust, publishIrohPairingPublicKey/Record, revokeIrohPairingRecord, XEdDSA verify, trust-chain canonical bytes
- `functions/src/callables/cloudVaultRotation.ts` — rotateCloudVaultKey (generation guard, requirement match, wrapper revoke)
- `functions/src/cloudVaultRotationResilience.ts` — listPendingCloudVaultRotationRequirements, detectStalePendingCloudVaultRotations
- `functions/src/appCheckAttestation.ts` — issueHighRisk nonce mint + consumeHighRiskNonceForUid + enforceHighRiskComputerUseCallableWithNonce
- `functions/src/config.ts` — requireHighRiskNonce / enforceAppCheck defaults
- `AgentLens/Services/CloudVaultTrustedDeviceChainVerifier.swift` — recursive client-side trust-chain walk
- `AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift` — revoke→rotate wiring, pickUpPendingCloudVaultRotations
- `AgentLens/App/AppDelegate.swift` — launch/foreground/post-revoke rotation pickup triggers
- `AgentLens/Services/ComputerUse/EscrowRevocationWatcher.swift` — revoked-device session teardown listener
- `AgentLens/Services/CloudSync/CloudVaultRotationRewrapWorker.swift` — rewrap of existing sealed data
- `AgentLens/Services/IrohRelay/IrohPairingPublicKeyPublisher.swift` — Mac publishes host pairing key
- `OpenBurnBarMobile/Services/IrohRelay/FirestoreIrohPairingPublicKeyProvider.swift` — iOS reads/verifies host pairing key
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ControllerKeyPinStore.swift` + `AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift` — controller-key TOFU pin + safety-code gate
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/EscrowDeviceSafetyCode.swift` — approve-time safety-code flag
- `firestore.rules` — escrow_devices, escrow_public_keys, signal_identity_public_keys, iroh_pairing(+controllers), iroh_pairing_keys, relay_sender_keys, cloud_vault_key_wrappers, cloud_vault_rotation_requirements

## Controls present
- Server-only trust elevation — `firestore.rules:3448 validEscrowDeviceCreate` (trustState != "trusted"), `:3453 validEscrowDeviceUpdate` (trustState + every identity field byte-identical) — strong — client cannot self-promote or swap fingerprint/approver/keyVersion.
- Trust-root collections server-only write — `firestore.rules:2665,2677,2774,2784` (iroh_pairing_keys / iroh_pairing / controllers / relay_sender_keys `allow create,update,delete: if false`) — strong — pairing roots writable only via Admin SDK callables.
- rotation requirements server-only — `firestore.rules:2365` (`if false`) — strong — client cannot forge/cancel a pending rotation requirement.
- XEdDSA (libsignal XEd25519) trust-chain verify server-side — `computerUseSecurity.ts:616 verifyXEdDSACurve25519Signature`, `:706 verifyCloudVaultDeviceTrustChainSignature`, called `:1396` in approveEscrowDeviceTrust — strong — approver key read from published Firestore doc, never from proof; scalar-malleability guard `:627-628`; fail closed `:1411`.
- Approver must be a DISTINCT trusted native device — `computerUseSecurity.ts:1263 requireTrustedNativeApprover`, `:1284-1290` (web always needs native approver) — strong.
- Bootstrap self-approval hard-requires fresh single-use nonce — `computerUseSecurity.ts:1334` (independent of global flag, enforced posture only) — strong against captured-owner replay of the first trust root.
- Single-use high-risk nonce, atomic consume — `appCheckAttestation.ts:179 consumeHighRiskNonceForUid` (txn checks consumedAt + expiry, `:205` marks consumed) — strong.
- requireHighRiskNonce default-ON in prod — `config.ts:92-95` (default = `looksProd`); warns loudly if explicitly disabled `:98` — moderate→strong (env-overridable).
- Server-side escrow fingerprint→key-bytes binding ENFORCED — `computerUseSecurity.ts:270 ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED = true`, fail-closed `:1248`, on-curve P-256 check `:246 isPointOnP256Curve` — strong.
- Client-side recursive trust-chain verify rooted at local identity, with fingerprint→bytes re-binding — `CloudVaultTrustedDeviceChainVerifier.swift:109` (escrow key), `:137` (signal key), `:192 CloudVaultDeviceTrustChain.verify` — strong — defeats backend key-swap before vault wrap.
- Atomic revoke — `computerUseSecurity.ts:1456` flips trustState, revokes grants `:1492`, revokes active vault wrappers `:1508`, deletes iroh controllers `:1573-1580`, deletes agent-grant authority `:1584-1588`, revokes Signal sessions `:1599`, emits receipt `:1617` — strong.
- Revoke→rotation requirement created — `computerUseSecurity.ts:1532-1557` (only when a surviving trusted device exists) — strong.
- Rotation generation monotonicity + requirement match — `cloudVaultRotation.ts:185` (advance by exactly one), `:198-217` (requirement status/key/generation/survivor-set match), survivor must include itself `:151`, old-gen wrappers revoked `:299-307` — strong.
- Client revoke→rotate inline + survivor pickup — `ComputerUseSecurityCallableClient.swift:302-309` (revoking device rotates), `:370 pickUpPendingCloudVaultRotations` (survivor Macs), `AppDelegate.swift:119,134,143` (launch/foreground/post-revoke) — strong (Mac-only, see gaps).
- Stale pending-rotation detector — `cloudVaultRotationResilience.ts:268 detectStalePendingCloudVaultRotations` (every 30 min) — moderate (alerting only, no auto-rotate).
- Revoked-device live-session teardown — `EscrowRevocationWatcher.swift:64-77` (listens trustState==revoked → panicHalt + populate revocation sets) — strong.
- Controller-key TOFU pin (Mac verifies phone) Keychain-backed, safety-code gate default ON — `ControllerKeyPinStore.swift:96 defaultEnabled = true`, `:186 verifyOrPin`, mismatch always refused `:198`, `PhoneControlAuthorityValidator.swift:202-225` — strong.
- Persisted per-peer replay counter + consumed-proof store survive restart, fail-closed on corruption — `PhoneControlAuthorityValidator.swift:133-143` — strong.

## Claims verified against code
- "Promotion requires a distinct trusted native approver's server-verified XEdDSA trust-chain signature" — Defensible — `computerUseSecurity.ts:1396,1263-1290,1411` — signature now cryptographically verified server-side (was NOT in older package).
- "Device revocation triggers vault key rotation" — Defensible (REMEDIATED) — revoke creates requirement `computerUseSecurity.ts:1532`; client rotates inline `ComputerUseSecurityCallableClient.swift:302`; survivor pickup `:370`+`AppDelegate.swift:119`. Internal package said UNWIRED — no longer true.
- "Revocation completes WITH re-encryption of existing content" — Partial — rewrap runs after rotation (`CloudVaultRotationRewrapWorker.swift:36,95`); a survivor must perform it. Mac AND Android both have full rotate+rewrap paths (`AndroidCloudVaultRevocationRotation.kt:135,263`); iOS-only survivor sets and trigger-coverage gaps still delay it (see T-PTR-02).
- "No claw-back of pre-revocation cached keys" — Defensible (gap acknowledged) — revoked-but-online/offline-cached device retains the old vault key until rotation+rewrap finish; nothing invalidates a key already in its memory/Keychain. SECURITY.md concedes this.
- "Host pairing key is long-lived and never auto-rotates; iOS pins it" — NotDefensible (overclaim) — `FirestoreIrohPairingPublicKeyProvider.swift:9-11,45` caches IN-MEMORY only; no Keychain pin, no safety-code, no persistence (see T-PTR-03).
- "User-visible safety code gates approval by default" — Partial — runtime controller-key safety gate default ON (`ControllerKeyPinStore.swift:96`), but the *approve-time* escrow safety-code COMPARE UI defaults OFF (`EscrowDeviceSafetyCode.swift:202 defaultEnabled = false`).
- "Pairing binds account + device + key" — Defensible — trust-chain canonical bytes bind uid+targetDeviceId+escrow fingerprint+keyVersion+signal identity ids/fingerprints (`computerUseSecurity.ts:663-699`); pin store account-scopes `uid|peerNodeId` (`ControllerKeyPinStore.swift:179`).
- "Malicious relay/Firestore cannot swap a controller key undetected" — Defensible — Keychain pin mismatch always refused (`ControllerKeyPinStore.swift:198`, `PhoneControlAuthorityValidator.swift:216-217`).
- "requireHighRiskNonce on by default in prod" — Defensible — `config.ts:92-95` default = looksProd.

## Threats
- T-PTR-01 — Revocation leaves vault key un-rotated (cached-key window) — STRIDE:I/E / framework T-ID-4,RR-5 — Medium — revokeEscrowDeviceTrust+rotation — A trusted device is compromised/lost; operator revokes. Revoke severs grants/controllers/sessions immediately and queues rotation. Until a survivor completes rotation+rewrap, the revoked device's already-cached vault key still decrypts pre-revocation synced content. Mitigation: inline + survivor + stale-detector rotation now wired. Gap: NO claw-back of the key already resident on the revoked device. Residual: time-bounded read of pre-revocation content by an offline thief; new wraps blocked. (Down-graded from the package's "rotation entirely unwired".)
- T-PTR-02 — Rotation requirement starves on uneven survivor-pickup trigger coverage — STRIDE:D / Agentic-availability — Medium — pickUpPendingCloudVaultRotations — Both Mac (`AppDelegate.swift:119,134,143` launch+foreground+post-revoke) and Android (`AndroidCloudVaultRevocationRotation.kt:135`, invoked `DevicesStore.kt:114`) can rotate, BUT Android only picks up a pending requirement "once per store instance ... from the devices surface's first load" (`DevicesStore.kt:110-115,193`) — i.e. only when the user opens the Devices screen, not on every app foreground. iOS has rewrap workers (`MobileCloudVaultRotationRewrapWorker.swift`) but no survivor rotate-pickup trigger observed. So if the revoking device is offline and the only online survivors are an iOS device or an Android device whose user never opens Devices, `cloud_vault_rotation_requirements/{id}` stays `pending`; `detectStalePendingCloudVaultRotations` (`cloudVaultRotationResilience.ts:268`) only flags, never auto-rotates. Gap: no server-driven rotation; liveness depends on a Mac foregrounding or an Android user visiting Devices. Residual: prolonged cached-key window for iOS-survivor or Devices-screen-avoidant fleets.
- T-PTR-03 — iOS host-pairing-key in-memory TOFU enables cloud-MITM dial redirection — STRIDE:S/T / LINDDUN-Detectability / RR (new) — High — FirestoreIrohPairingPublicKeyProvider — Cloud is untrusted (ground rule). The phone verifies the Mac's signed iroh NodeAddr against `iroh_pairing_keys/host.publicKeyBase64` fetched from Firestore and cached in-memory only, with NO Keychain pin / safety-code / persistence (`FirestoreIrohPairingPublicKeyProvider.swift:9-11,45`). A malicious backend serving a swapped host key to a cold-start session can make the phone accept an attacker-signed NodeAddr and dial an attacker NodeId. Mitigation (defense-in-depth): control intents still gated by Mac-side controller pin + Signal at-rest sealer, so this is transport MITM/redirection, not direct command injection. Gap: asymmetric — Mac→phone direction is Keychain-pinned, phone→Mac is not. Residual: relay/transport interception, traffic-analysis, fallback coercion on first/cold pairing.
- T-PTR-04 — Approve-time safety-code compare UI default OFF — STRIDE:S / LINDDUN — Medium — EscrowDeviceTrustSafetyCheckFlag — `EscrowDeviceSafetyCode.swift:202 defaultEnabled = false`: an operator approving a new device is NOT, by default, prompted to compare an out-of-band safety code at approve time. Server fingerprint→bytes binding (`:270`) and the trust-chain signature still bind the key, and the runtime controller pin gate is ON — so the user-facing OOB confirmation at the moment of approval is the missing layer. Residual: a captured-but-valid approval flow that App Check + nonce pass admits a device the human never visually confirmed.
- T-PTR-05 — TOFU first-pairing window on controller key — STRIDE:S / T-TR — Low/Medium — ControllerKeyPinStore — First-ever controller key is pinned unconfirmed (`ControllerKeyPinStore.swift:199-212 pinnedFirstUse`); with the gate ON it requires operator safety-code confirmation before admission (`PinResult.admits:139-148`), with the gate OFF it is admitted on first use. If `ControllerKeyPinEnforcementFlag` is force-disabled (UserDefaults override `:94`) a relay-supplied key is silently trusted on first contact. Residual: first-contact key poisoning only when the secure-default gate is overridden off.
- T-PTR-06 — Client-writable cloud_vault_key_wrappers lacks generation-monotonicity / rotation-job binding in rules — STRIDE:T/E — Low — firestore.rules:2209 — Owner client may create/update wrappers when target+source are trusted and vaultKeyID matches current (`:2230-2253`), but the rule does not require the wrapper to originate from a `rotateCloudVaultKey` job or that `vaultGeneration` advance. Rotation-path wrappers are Admin-SDK-written and out-of-band of this rule, so the risk is a stolen-session owner writing extra same-generation wrappers, not trust elevation. Residual: limited — bounded by current-vault-key match and trusted-device existence.

## Gaps / missing controls
- No claw-back: nothing invalidates a vault key already resident on a revoked device (acknowledged in SECURITY.md). Rotation only stops FUTURE wraps + re-encrypts existing data.
- Rotation liveness is Mac-dependent: no server/Cloud-Function actor rotates; Android/iOS-only survivor sets cannot retire a revoked key (only flagged stale).
- iOS host pairing key not persistently pinned (no Keychain, no safety number) — asymmetric vs the Mac-side controller pin.
- Approve-time human safety-code compare defaults OFF; relies on cryptographic binding + runtime pin instead of an OOB visual check at approval.
- `detectStalePendingCloudVaultRotations` alerts but does not remediate; no escalation path verified for permanently-stuck requirements.

## Overclaims
- Doc/comment "iOS pins / never-auto-rotates host pairing key" overstates — it is in-memory cache only, re-fetched fresh each cold session from untrusted Firestore (`FirestoreIrohPairingPublicKeyProvider.swift:9-11`).
- Any prose stating "revocation completes with key rotation AND re-encryption" should be qualified to "when a Mac survivor performs the rotation"; mixed/Android-survivor and offline cases leave it pending (T-PTR-02).
- Internal package overclaim #7 ("rotation trigger unwired") is now STALE — current code wires it; the live overclaim is the host-key pinning claim instead.

## Crypto / protocol notes
- Trust-chain signature is libsignal XEd25519 (XEdDSA over Curve25519): Montgomery-u → compressed Edwards reconstruction with sign bit from signature[63] (`computerUseSecurity.ts:616-650`), non-canonical scalar rejected (`:627-628`), verified via Node ed25519 over reconstructed SPKI. Canonical bytes are domain-prefixed length-prefixed UTF-8 segments (`:663-699`), matching the Swift signer (`CloudVaultDeviceTrustChain.swift`). Approver public key sourced ONLY from published Firestore identity doc — attacker cannot supply a matching key/sig pair.
- Vault-key wrapping: ECIES-P256-AESGCM survivor wrappers; rotation enforces generation = current+1 and revokes all old-vaultKeyID wrappers (`cloudVaultRotation.ts:185,299-307`).
- Fingerprints are base64(SHA256(keyBytes)); both server (`:287 recomputeEscrowFingerprint`) and client (`CloudVaultTrustedDeviceChainVerifier.swift:109,137`) re-bind the signed fingerprint STRING to actual key BYTES so a backend key-swap-under-a-signed-fingerprint fails closed.

## Open questions / UNKNOWN
- Deployed `REQUIRE_HIGH_RISK_NONCE` / `ENFORCE_APP_CHECK` / `openburnbar.require_high_risk_nonce` values in the prod project — code default is prod-ON but an env/Remote-Config override could disable nonce replay defense. Needs deployed config to confirm.
- `ControllerKeyPinEnforcementFlag` and `EscrowDeviceTrustSafetyCheckFlag` UserDefaults overrides on shipping builds — code defaults are ON/OFF respectively but a provisioning profile / MDM could flip them. Needs device inspection.
- Whether Android has ANY vault-rotation trigger (only rewrap worker seen) — if none, T-PTR-02 is firmer. Needs android/ rotation-path grep.
- Does any flow invalidate Firebase/Auth session of the revoked device (forcing re-auth)? Not observed in revoke path — would shrink the cached-key window if present.
