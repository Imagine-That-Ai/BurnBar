# `try?` security-matters findings — Swarm 2 (try? burn-down, security-first)

**Date:** 2026-06-14  
**Source:** conservative triage of `try?` sites in security-adjacent `AgentLens/Services` during the error-debt burn-down (Swarm 2).  
**Status:** these sites are deliberately **left untagged** in `budgets/try-optional-baseline.json` — they remain counted as debt. Each one swallows an error that drives a security or correctness decision, so it must be fixed with a *tested* `do/catch` (often **fail-closed**), not tagged `try?-ok` and not laundered through `silently(fallback:)` (which would preserve the fail-open).

Tagging these would hide a real defect; converting them blindly without a test risks shipping an untested security behavior change. They are catalogued here for the security / coverage-first follow-up tranche (plan Phase 1/2).

**Count:** 19 sites across 9 files.

| # | Severity | File:Line | Sync/Async | One-line risk |
|---|----------|-----------|------------|---------------|
| 1 | CRITICAL | `CloudSync/CLIAgentMissionRequestListener.swift:1582` | sync | SECURITY-CRITICAL: this try? swallows a throw that is THROWN BY DESIGN as a security control |
| 2 | CRITICAL | `CloudSync/HermesRelayHostService.swift:1054` | async | The snapshot is used to decide isEncrypted via (snapshot?.data()?["schemaVersion"] as? Int ?? 1) >= 2 |
| 3 | CRITICAL | `CloudSync/UsageSyncService.swift:199` | sync | This decrypts (opens) a sealed project-name envelope and the result drives an explicit security decision: on failure the |
| 4 | HIGH | `CloudBudgetService.swift:126` | async | This acquires a cloud-vault CRYPTO KEY (used to open sealed project names/labels) |
| 5 | HIGH | `CloudSync/ChatThreadSyncService.swift:83` | sync | This is the message body read that feeds the encrypted cloud backup payload, not a skippable cache/sidecar read |
| 6 | HIGH | `CloudSync/ConversationCloudVaultPayload.swift:167` | sync | This decode sits inside the Signal sealed-open security flow (ConversationCloudSealer.open) |
| 7 | HIGH | `CloudSync/DownloadSyncService.swift:330` | async | This reads a vault crypto key (keyForReading) that is used immediately at line 349 to open the sealed project name via C |
| 8 | HIGH | `CloudSync/DownloadSyncService.swift:453` | async | This reads the conversation vault crypto key and its signalIdentity, which then drive both decryption (ConversationCloud |
| 9 | HIGH | `CloudSync/HermesRelayHostService.swift:299` | sync | Reads the relay P-256 public key to publish into the host's Firestore connection doc so peers can encrypt to this host |
| 10 | HIGH | `CloudSync/HermesRelayHostService.swift:433` | sync | Same as line 299 but on the legacy-replacement publish path advertising the V3 gateway relay key version |
| 11 | HIGH | `CloudSync/HermesRelayHostService.swift:1267` | sync | Parses the stored relay identity private key from the keychain |
| 12 | HIGH | `CloudSync/PiAgentCloudRelayHostService.swift:133` | sync | Touches a crypto identity key (the relay P-256 public key advertised to clients) |
| 13 | HIGH | `CloudSync/PiAgentCloudRelayHostService.swift:706` | sync | This silently swallows a failure to parse the stored relay PRIVATE key |
| 14 | HIGH | `CloudSync/SessionLogSyncService.swift:1656` | sync | This is an authenticated AES-GCM decryption (CloudVaultCrypto.openText -> AES.GCM.open) of a sealed search-result title  |
| 15 | HIGH | `CloudSync/SessionLogSyncService.swift:1659` | sync | Same authenticated-decryption concern as line 1656, applied to the sealed search-result snippet |
| 16 | MEDIUM | `CloudBudgetService.swift:169` | sync | This is the ENCODE (write/upload) side, not a decode-with-fallback |
| 17 | MEDIUM | `CloudSync/CLIAgentMissionRequestListener.swift:623` | async | This is a Firestore write to the device-trust document (escrow trust collection) inside a fire-and-forget detached Task |
| 18 | MEDIUM | `CloudSync/DownloadSyncService.swift:91` | async | This is a cloud Firestore write (not a local-disk cache/marker write and not telemetry posting), so it falls outside the |
| 19 | MEDIUM | `CloudSync/UsageSyncService.swift:185` | sync | This is a keyed-crypto trapdoor call (HMAC under the per-user search key) that produces the cross-platform projectKeyHas |

---

## 1. [CRITICAL] `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift:1582` (sync)

```swift
let personaOverrides = (try? CLIAgentMissionPersonaScopeApplier.overrides(from: data))
            ?? .empty
```

**Why it matters:** SECURITY-CRITICAL: this try? swallows a throw that is THROWN BY DESIGN as a security control. The source of overrides(from:) (OpenBurnBarCore/.../CLIAgentMissionPersonaScopeApplier.swift:26-30) carries the explicit contract: 'throws on malformed JSON so the listener surfaces a clear error instead of silently dispatching with default permissions.' The decoded RuntimeOverrides/PersonaScopeEnvelope carries the persona's permission gating: permitShell, permitFileEdits, permittedTools allowlist, permittedFileGlobs, permittedShellPrefixes (see buildEnvironment, lines 44-69). Using try? ... ?? .empty means a malformed/tampered persona-scope payload is silently dropped and the mission dispatches with .empty overrides — i.e. with NO persona shell/file/tool restrictions applied, the exact 'default permissions' fall-open the contract was written to prevent. A phone-supplied (untrusted-origin) mission request that corrupts personaScopeJSON would bypass the persona sandbox. This drives a security decision and MUST fail closed, not be tagged as debt.

**Suggested fix:**

```
Stop swallowing the throw; fail the mission closed when persona scope is malformed:

let personaOverrides: CLIAgentMissionPersonaScopeApplier.RuntimeOverrides
do {
    personaOverrides = try CLIAgentMissionPersonaScopeApplier.overrides(from: data)
} catch {
    AppLogger.cloudSync.error("refusing mission \(requestID): malformed personaScopeJSON, cannot apply persona permission scope: \(error.localizedDescription)")
    return DirectCLIMissionResult(
        status: "failed",
        output: "",
        errorMessage: "Mission persona scope could not be verified; refusing to run with default permissions.",
        sessionID: "persona-scope-reject-\(UUID().uuidString)"
    )
}

(Returning nil / a failed DirectCLIMissionResult preserves the contract's intent of not silently dispatching with default permissions.)
```

## 2. [CRITICAL] `AgentLens/Services/CloudSync/HermesRelayHostService.swift:1054` (async)

```swift
let snapshot = try? await reference.getDocument()
```

**Why it matters:** The snapshot is used to decide isEncrypted via (snapshot?.data()?["schemaVersion"] as? Int ?? 1) >= 2. On a failed fetch the default is schemaVersion 1, so isEncrypted becomes false and the raw plaintext error message is written into the cloud Firestore doc. For an actually-encrypted (schemaVersion >= 2) request this is a fail-open that leaks plaintext error text into the cloud. The failure path drives a confidentiality decision.

**Suggested fix:**

```
do { let snapshot = try await reference.getDocument(); let isEncrypted = (snapshot.data()?["schemaVersion"] as? Int ?? 1) >= 2; if !isEncrypted { statusUpdate["error"] = String(message.prefix(2_000)) } } catch { AppLogger.network.error("hermes_relay_fail_encryption_probe_failed", error: error) /* fail closed: do NOT write plaintext error when encryption state is unknown */ }
```

## 3. [CRITICAL] `AgentLens/Services/CloudSync/UsageSyncService.swift:199` (sync)

```swift
if let keyData, let plaintext = try? openText(envelope, keyData: keyData) {
```

**Why it matters:** This decrypts (opens) a sealed project-name envelope and the result drives an explicit security decision: on failure the function returns nil to avoid leaking a legacy plaintext value (comment line 202 'Sealed but unreadable on this device - do not leak a legacy value'). This is sealing/decryption of a private payload and a device-trust/confidentiality decision - squarely in the MATTERS category. The try? conflates 'wrong key on this device' (expected, return nil) with a genuine crypto/parse fault, and silently swallows both with no telemetry, hiding real open failures. Do not tag.

**Suggested fix:**

```
Distinguish expected key-mismatch from real faults and log the latter:
    if let keyData {
        do {
            return try openText(envelope, keyData: keyData)
        } catch {
            AppLogger.cloudSync.debug("sealed projectName not openable on this device: \(error.localizedDescription, privacy: .public)")
            // Sealed but unreadable on this device - do not leak a legacy value.
            return nil
        }
    }
    return nil
```

## 4. [HIGH] `AgentLens/Services/CloudBudgetService.swift:126` (async)

```swift
let vaultKey = try? await vaultKeyProvider.keyForReading(uid: uid, deviceId: accountManager.deviceId)?.keyData
```

**Why it matters:** This acquires a cloud-vault CRYPTO KEY (used to open sealed project names/labels). It touches an identity/crypto-key provider, an explicit MATTERS category. Although the surrounding comment frames it as best-effort and decodeRule(vaultKey:) does accept a nil key (sealed peers are skipped, legacy plaintext still decodes), the bare try? silently swallows ALL provider errors with no logging. A genuine escrow/provisioning/keychain fault would be indistinguishable from the benign not-yet-escrowed case, so a real key-acquisition regression would silently degrade every sealed rule to undecodable without any signal. Per the rule that crypto-key acquisition results are MATTERS and uncertainty defaults to MATTERS, left untagged.

**Suggested fix:**

```
Replace the bare try? with do/catch that distinguishes the benign absent-key case from real failures and logs the latter:

        let vaultKey: Data?
        do {
            vaultKey = try await vaultKeyProvider.keyForReading(uid: uid, deviceId: accountManager.deviceId)?.keyData
        } catch {
            AppLogger.sync.silentFailure(
                "budget_vault_key_read_failed",
                error: error,
                context: ["retry": "next_sync_cycle", "effect": "sealed_rules_skipped"]
            )
            vaultKey = nil
        }

This preserves the documented nil fallback (sealed peers skipped) while making a real key fault observable instead of silent.
```

## 5. [HIGH] `AgentLens/Services/CloudSync/ChatThreadSyncService.swift:83` (sync)

```swift
? ((try? context.dataStore.fetchChatMessages(threadID: thread.id)) ?? [])
```

**Why it matters:** This is the message body read that feeds the encrypted cloud backup payload, not a skippable cache/sidecar read. On any failure of fetchChatMessages (transient DB lock, decrypt error, corruption) the try? swallows the error and substitutes [] (empty messages). That empty list is then encoded into ChatThreadSealedPayload (line 103), sealed (lines 105-114), and written to Firestore with batch.setData(..., merge: true) (line 155). Because sealedPayload is fully replaced on merge, a transient read failure silently OVERWRITES a previously-good backup with a record that contains zero messages while messageCount (line 91) still reports the real non-zero count, i.e. silent backup data loss / corrupted backup state. The function already has an outer do/catch (lines 54-174, sets lastSyncError); this try? deliberately bypasses that real error handling. This drives a correctness/data-integrity decision in a security backup path and is not one of the allowed best-effort categories, so it must not be tagged.

**Suggested fix:**

```
Replace the silent try? with explicit do/catch that surfaces the failure instead of writing an empty-content backup. Either let the error propagate to the outer catch (so the whole sync records lastSyncError and is retried), or log and skip THIS thread entirely so no over-writing empty-content record is produced:

    let messages: [ChatMessageRecord]
    if includeContent {
        do {
            messages = try context.dataStore.fetchChatMessages(threadID: thread.id)
        } catch {
            AppLogger.sync.error(
                "chat_thread_fetch_messages_failed_skipping_thread",
                metadata: ["accountUid": uid, "threadId": thread.id, "error": String(describing: error)]
            )
            continue // do not overwrite a prior good backup with an empty-content record
        }
    } else {
        messages = []
    }

(If overwriting prior backups is not a concern and aborting the batch is preferred, drop the do/catch and use `try context.dataStore.fetchChatMessages(threadID: thread.id)` so the outer catch handles it.)
```

## 6. [HIGH] `AgentLens/Services/CloudSync/ConversationCloudVaultPayload.swift:167` (sync)

```swift
), let payload = try? decoder.decode(ConversationCloudPrivatePayload.self, from: bytes) {
```

**Why it matters:** This decode sits inside the Signal sealed-open security flow (ConversationCloudSealer.open). The bytes have ALREADY been sender-authenticated/decrypted by MacCloudVaultSignalPayloads.openSignalPayloadIfPresent (the un-`?` `try` above, whose forgery/downgrade failures fail CLOSED in the explicit catch blocks). When `try?` here returns nil, the `if let` fails, so the function does NOT return the decoded payload and instead silently falls through past the do/catch to the legacy AES-GCM opener at line 186 — a downgrade of the open path. A decode failure on already-authenticated bytes is an internal inconsistency, not expected-malformed input; swallowing it with `try?` masks the anomaly (no log, unlike the sibling catch at line 183) and lets a successfully sender-authenticated-but-undecodable payload silently route to the legacy path. This `try?` outcome drives a security/correctness decision on a sealed-payload open path, so per the rules it MATTERS and must not be tagged.

**Suggested fix:**

```
Replace the inline `try?` with an explicit do/catch so a decode failure of authenticated bytes is logged and the fallthrough is deliberate, e.g.:

```swift
if let bytes = try MacCloudVaultSignalPayloads.openSignalPayloadIfPresent(
    data, uid: uid, collection: "conversations", docId: docId,
    signalIdentity: signalIdentity, trustedSenderPublicKeys: trustedSenderPublicKeys
) {
    do {
        return try decoder.decode(ConversationCloudPrivatePayload.self, from: bytes)
    } catch {
        AppLogger.cloudSync.error("Authenticated Signal conversation payload failed to decode; falling back to legacy vault open: \(String(describing: error), privacy: .private)")
    }
}
```
(Use the project's AppLogger/Logger instance already present as `logger` in this enum if AppLogger is not in scope; the point is to log the anomaly rather than silently swallow it.)
```

## 7. [HIGH] `AgentLens/Services/CloudSync/DownloadSyncService.swift:330` (async)

```swift
let usageVaultKey = try? await conversationVaultKeyProvider.keyForReading(uid: uid, deviceId: localDeviceId)
```

**Why it matters:** This reads a vault crypto key (keyForReading) that is used immediately at line 349 to open the sealed project name via CloudVaultCrypto.openSealedProjectName(from:keyData:). This squarely touches identity/crypto keys and the open/unseal path, which the rules call out as an ESPECIALLY-matters category. The try? collapses two very different failure modes into a single nil: (a) the device is genuinely un-approved / has no key (an expected, benign skip), versus (b) the key provider threw a real error (keychain failure, decode error, transient backend error). Both silently degrade every sealed row in the batch to projectName "" with no log, so a recoverable provider error is indistinguishable from intended degradation and produces silent data loss of project names across the whole sync cycle. That swallowed-error ambiguity is debt and must not be tagged as clean best-effort.

**Suggested fix:**

```
let usageVaultKey: CloudVaultResolvedKey?
do {
    usageVaultKey = try await conversationVaultKeyProvider.keyForReading(uid: uid, deviceId: localDeviceId)
} catch {
    usageVaultKey = nil
    AppLogger.sync.error("download_sync_usage_vault_key_read_failed", metadata: ["accountUid": uid, "deviceId": localDeviceId, "error": String(describing: error)])
}
```

## 8. [HIGH] `AgentLens/Services/CloudSync/DownloadSyncService.swift:453` (async)

```swift
vaultKey = try? await conversationVaultKeyProvider.keyForReading(uid: uid, deviceId: localDeviceId)
```

**Why it matters:** This reads the conversation vault crypto key and its signalIdentity, which then drive both decryption (ConversationCloudSealer.open at line 461, keyData: vaultKey?.keyData) AND sender signature / trust-chain verification (the signalIdentity feeds MacCloudVaultSignalPayloads.trustedSenderPublicKeys at line 456 and is passed as signalIdentity into the open call). This is exactly the prohibited zone: crypto keys plus signature/trust-chain verification. A try? here makes a real key-provider error (keychain, identity load, backend) indistinguishable from a legitimate un-approved device, silently disabling cross-device sender verification and dropping every sealed conversation in the batch (guard ... else continue) with no diagnostic. Swallowing this hides a security-relevant failure and must not be tagged.

**Suggested fix:**

```
do {
    vaultKey = try await conversationVaultKeyProvider.keyForReading(uid: uid, deviceId: localDeviceId)
} catch {
    AppLogger.sync.error("download_sync_conversation_vault_key_read_failed", metadata: ["accountUid": uid, "deviceId": localDeviceId, "error": String(describing: error)])
    vaultKey = nil
}
```

## 9. [HIGH] `AgentLens/Services/CloudSync/HermesRelayHostService.swift:299` (sync)

```swift
if let publicKey = try? relayKeyStore.existingPublicKeyBase64() {
```

**Why it matters:** Reads the relay P-256 public key to publish into the host's Firestore connection doc so peers can encrypt to this host. A silent failure publishes the connection WITHOUT relayPublicKey/keyVersion/encryption fields, which can push peers onto a legacy/unencrypted path or break E2EE setup. This is crypto key material driving an encryption decision, not best-effort.

**Suggested fix:**

```
do { if let publicKey = try relayKeyStore.existingPublicKeyBase64() { data["relayPublicKey"] = publicKey; data["relayKeyVersion"] = HermesRelayCrypto.keyVersion; data["relayEncryption"] = HermesRelayCrypto.algorithm } } catch { AppLogger.network.silentFailure("hermes_relay_public_key_publish_failed", error: error) } -- and consider refusing to publish an online connection without a key rather than advertising a keyless host.
```

## 10. [HIGH] `AgentLens/Services/CloudSync/HermesRelayHostService.swift:433` (sync)

```swift
if let publicKey = try? relayKeyStore.existingPublicKeyBase64() {
```

**Why it matters:** Same as line 299 but on the legacy-replacement publish path advertising the V3 gateway relay key version. Silently omitting relayPublicKey here means the replacement connection advertises no V3 key, undermining the encryption upgrade. Crypto key material gating an encryption decision -> must not fail silently.

**Suggested fix:**

```
do { if let publicKey = try relayKeyStore.existingPublicKeyBase64() { data["relayPublicKey"] = publicKey; data["relayKeyVersion"] = HermesRelayCrypto.gatewayRelayKeyVersionV3; data["relayEncryption"] = HermesRelayCrypto.relayEncryptionV3 } } catch { AppLogger.network.error("hermes_relay_legacy_public_key_publish_failed", error: error); return } so the keyless replacement is not published.
```

## 11. [HIGH] `AgentLens/Services/CloudSync/HermesRelayHostService.swift:1267` (sync)

```swift
let key = try? HermesRelayPrivateKey(rawRepresentation: data) {
```

**Why it matters:** Parses the stored relay identity private key from the keychain. On a parse failure the if-let chain falls through and the function silently GENERATES AND PERSISTS A NEW private key (lines 1270-1272), destroying key/identity continuity. A corrupt or transiently-unreadable stored key is silently replaced rather than surfaced, which is an identity/signing-key decision that must not fail silently.

**Suggested fix:**

```
Replace try? with explicit handling: do { let key = try HermesRelayPrivateKey(rawRepresentation: data); return key } catch { AppLogger.network.error("hermes_relay_stored_key_unparseable", error: error) }; then only regenerate after deliberately confirming no recoverable key exists, so a transient/corrupt read does not silently rotate the host identity.
```

## 12. [HIGH] `AgentLens/Services/CloudSync/PiAgentCloudRelayHostService.swift:133` (sync)

```swift
if let publicKey = try? relayKeyStore.existingPublicKeyBase64() {
```

**Why it matters:** Touches a crypto identity key (the relay P-256 public key advertised to clients). existingPublicKeyBase64() can throw from keychain access and the ephemeral fallback path; this try? silently swallows that failure and omits relayPublicKey/relayKeyVersion/relayEncryption from the published connection record with no log. The online counterpart publishRelayConnection uses non-optional `try` with explicit error handling and always advertises the key, so this offline path silently diverges. A swallowed key-read failure here is exactly the kind of crypto error that hides debt and should be observable, not dropped.

**Suggested fix:**

```
do {
    let publicKey = try relayKeyStore.existingPublicKeyBase64()
    if let publicKey {
        data["relayPublicKey"] = publicKey
        data["relayKeyVersion"] = PiAgentRelayCrypto.keyVersion
        data["relayEncryption"] = PiAgentRelayCrypto.algorithm
    }
} catch {
    AppLogger.network.silentFailure("pi_agent_relay_offline_public_key_read_failed", error: error)
}
```

## 13. [HIGH] `AgentLens/Services/CloudSync/PiAgentCloudRelayHostService.swift:706` (sync)

```swift
let key = try? PiAgentRelayPrivateKey(rawRepresentation: data) {
```

**Why it matters:** This silently swallows a failure to parse the stored relay PRIVATE key. When the throwing initializer fails (corrupt/incompatible stored bytes), try? yields nil, the if-let chain falls through, and the code generates a brand-new private key (line 709) — silently rotating the host's crypto identity so every client holding the previously advertised public key can no longer reach this host. The same initializer is used with non-optional `try` at lines 735, 749, and 756, confirming the codebase normally propagates this error; line 706 is the anomaly. A swallowed private-key parse error that triggers silent key regeneration is a security/correctness decision and must be logged, not dropped.

**Suggested fix:**

```
if let stored = try keychain.string(for: account),
   let data = Data(base64Encoded: stored) {
    do {
        return try PiAgentRelayPrivateKey(rawRepresentation: data)
    } catch {
        AppLogger.network.error(
            "pi_agent_relay_stored_private_key_parse_failed_regenerating",
            metadata: ["error": error.localizedDescription]
        )
    }
}
let key = PiAgentRelayCrypto.generatePrivateKey()
```

## 14. [HIGH] `AgentLens/Services/CloudSync/SessionLogSyncService.swift:1656` (sync)

```swift
.flatMap { try? CloudVaultCrypto.openText($0, keyData: vaultKey) }
```

**Why it matters:** This is an authenticated AES-GCM decryption (CloudVaultCrypto.openText -> AES.GCM.open) of a sealed search-result title coming from the server. Swallowing the throw with try? silently collapses two very different cases into the same '?? "Encrypted session"' fallback: (a) a benign empty/absent field, and (b) an AEAD authentication failure, which in a security product is the signal that a server-controlled search-index entry was tampered with or forged. Hiding a decryption/integrity failure on a server-sourced ciphertext drops a security-relevant signal and is exactly the crypto/decrypt category the tagging rules say must NOT be tagged.

**Suggested fix:**

```
Replace the optional-try with explicit do/catch so genuine 'no value' stays distinct from authentication failures:

let title: String
do {
    if let sealed = Self.decodeSealedText(hit["sealedTitle"]) {
        title = try CloudVaultCrypto.openText(sealed, keyData: vaultKey)
    } else {
        title = "Encrypted session"
    }
} catch {
    AppLogger.cloudSync.error("Failed to open sealed search title for \(documentID): \(error.localizedDescription)")
    title = "Encrypted session"
}

This preserves the display fallback while logging (and making auditable) any AEAD/authentication failure on server-supplied ciphertext instead of silently discarding it.
```

## 15. [HIGH] `AgentLens/Services/CloudSync/SessionLogSyncService.swift:1659` (sync)

```swift
.flatMap { try? CloudVaultCrypto.openText($0, keyData: vaultKey) }
```

**Why it matters:** Same authenticated-decryption concern as line 1656, applied to the sealed search-result snippet. try? on CloudVaultCrypto.openText (AES.GCM.open) silently equates an AEAD authentication/tamper failure on server-controlled data with an empty snippet via '?? ""'. In a security product a failed authenticated decryption of a server-sourced envelope is a forgery/tamper signal that must be surfaced, not swallowed; this is the crypto/decrypt category excluded from tagging.

**Suggested fix:**

```
Use do/catch to distinguish absent values from authentication failures and log the latter:

let snippet: String
do {
    if let sealed = Self.decodeSealedText(hit["sealedSnippet"]) {
        snippet = try CloudVaultCrypto.openText(sealed, keyData: vaultKey)
    } else {
        snippet = ""
    }
} catch {
    AppLogger.cloudSync.error("Failed to open sealed search snippet for \(documentID): \(error.localizedDescription)")
    snippet = ""
}

Keeps the empty-string display fallback while making any decryption/integrity failure on server-supplied ciphertext observable.
```

## 16. [MEDIUM] `AgentLens/Services/CloudBudgetService.swift:169` (sync)

```swift
"fallbackCredentialIDsJSON": (try? JSONEncoder().encode(rule.fallbackCredentialIDs)).flatMap { String(data: $0, encoding: .utf8) } as Any,
```

**Why it matters:** This is the ENCODE (write/upload) side, not a decode-with-fallback. A silent encode failure drops the rule's fallbackCredentialIDs entirely from the Firestore doc that other seats download, which changes budget-enforcement behavior (a rule that should fall back to other credentials would lose that config cross-seat). That is a result that drives a correctness decision, so the allowed 'optional JSON DECODE with fallback' category does not apply. Encoding a [String] rarely fails, but a silent drop of synced rule config with no log is a correctness hazard; left untagged per the do-not-tag-when-it-drives-correctness rule.

**Suggested fix:**

```
Encode explicitly so an encode failure is logged rather than silently dropping the field. Hoist it above the dictionary literal:

        let fallbackJSON: String?
        do {
            fallbackJSON = String(data: try JSONEncoder().encode(rule.fallbackCredentialIDs), encoding: .utf8)
        } catch {
            AppLogger.sync.silentFailure(
                "budget_rule_fallback_encode_failed",
                error: error,
                context: ["ruleID": rule.id]
            )
            fallbackJSON = nil
        }

then reference "fallbackCredentialIDsJSON": fallbackJSON as Any in the literal. Behavior is preserved (nil is still stripped by compactMapValues) but a real failure becomes observable.
```

## 17. [MEDIUM] `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift:623` (async)

```swift
try? await self.registerPendingMac(deviceRef: snapshot.reference, deviceID: deviceID, mergeOnly: true)
```

**Why it matters:** This is a Firestore write to the device-trust document (escrow trust collection) inside a fire-and-forget detached Task. While mergeOnly:true means it cannot escalate trustState (it only refreshes deviceName/appVersion/updatedAt metadata on a pending record), it is a state mutation on a security-relevant device-trust record. None of the allowed best-effort categories cover a remote write to a trust document, and silent failure here means the device-trust record drifts/staling with no signal. Per the conservative rule (device-trust decisions / writes -> UNCERTAIN -> MATTERS), it is left untagged. Note: the swallowed error is genuinely non-fatal to the caller (the function returns .untrusted regardless), so this is the weaker of the two findings, but it still touches the trust collection.

**Suggested fix:**

```
Replace the try? with explicit do/catch that logs the failure so a staling trust record is observable:

Task { @MainActor in
    do {
        try await self.registerPendingMac(deviceRef: snapshot.reference, deviceID: deviceID, mergeOnly: true)
    } catch {
        AppLogger.cloudSync.error("failed to refresh pending Mac device-trust record \(deviceID): \(error.localizedDescription)")
    }
}
```

## 18. [MEDIUM] `AgentLens/Services/CloudSync/DownloadSyncService.swift:91` (async)

```swift
try? await devicesRef.document(gate.account.deviceId).setData(["deviceName": name], merge: true)
```

**Why it matters:** This is a cloud Firestore write (not a local-disk cache/marker write and not telemetry posting), so it falls outside the enumerated best-effort categories. It silently discards every failure (auth, network, permission, quota) with no logging, no retry, and no caller signal. The contrast with the device-registry write at line 102 — which wraps the same kind of setData in withCloudSyncRetry + circuit breaker + a do/catch that logs — shows the codebase treats real registry writes as deserving error handling; this bare try? is the odd one out. Although deviceName is cosmetic metadata (device-trust keys off deviceId, not the label), the swallowed failure means the cloud device registry can silently drift from the actual device name with zero observability, which is a debt-worthy correctness/observability gap, not a clean best-effort site. Per the conservative rule (uncertain -> treat as matters), it is left untagged.

**Suggested fix:**

```
do {
    try await devicesRef.document(gate.account.deviceId).setData(["deviceName": name], merge: true)
} catch {
    AppLogger.sync.error("download_sync_device_name_update_failed", metadata: ["deviceId": gate.account.deviceId, "error": error.localizedDescription])
}
```

## 19. [MEDIUM] `AgentLens/Services/CloudSync/UsageSyncService.swift:185` (sync)

```swift
return try? tokenHashes(for: normalized, keyData: keyData, limit: 1).first
```

**Why it matters:** This is a keyed-crypto trapdoor call (HMAC under the per-user search key) that produces the cross-platform projectKeyHash group-by bucket. The try? silently swallows any error from tokenHashes, which touches crypto key material and drives a correctness decision: the hash MUST be byte-identical to the Android writer so the same project name buckets into ONE cross-platform group (see doc lines 178-181). A swallowed failure silently drops the group-by token with no log, hiding a real crypto/derivation failure. Not in any allowed best-effort category (touches crypto keys; result drives correctness). Conservative rule: do not tag.

**Suggested fix:**

```
Replace the try? with explicit error handling so the failure surfaces:
    do {
        return try tokenHashes(for: normalized, keyData: keyData, limit: 1).first
    } catch {
        AppLogger.cloudSync.error("projectKeyHash derivation failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }
```

