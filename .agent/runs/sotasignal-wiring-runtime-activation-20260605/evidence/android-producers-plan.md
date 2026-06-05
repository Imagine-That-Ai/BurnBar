# Item 3 — Android producers (P2) — port spec + plan

Android has **zero** Signal producers today (map: AssistantChatHistoryStore + CLIAgentMissionDispatcher write/read are AES-GCM-only; no `AndroidCloudVaultSignalPayloads`, no `AndroidSignalIdentityKeyStore`, no `signal_identity_public_keys` publishing). The crypto primitives exist + are tested: `CloudVaultCrypto.sealSignalPayload`/`openSignalPayload` (CloudVaultCrypto.kt:318/353), `CloudVaultCryptoSupport.atRestSeal`/`atRestOpen` (44-59), `signalEnvelopeMap`/`signalEnvelopeFromMap` (439/476). libsignal comes from maven (`org.signal:libsignal-client`), so this is JVM-buildable here (NOT blocked on item 2).

## Reference to port (iOS): `OpenBurnBarMobile/Services/MobileCloudVaultSignalPayloads.swift`

`signalEnvelopeIfEnabled(domainID, uid, firestore, collection, docId, field, plaintext, resolvedKey)`:
1. `guard signalSealingIsEnabled(domainID)` else return nil  →  gate = `DataDomains.domain(domainID)?.sealingScheme == signalAtRestEncryption`.
2. binding = `{uid, collection, docId, field}`.
3. recipients = `atRestRecipients(uid, firestore, localIdentity)` — local identity + every `escrow_devices` where trustState==trusted, resolved to its `signal_identity_public_keys/{deviceId}_{keyVersion}` doc (validates deviceId/identityKeyId/keyVersion/algorithm/publicKeyData), sorted by identityKeyId.
4. `envelope = sealPayload(plaintext, recipients, binding)` → return `signalEnvelopeDictionary(envelope)`.

`openSignalPayloadIfPresent(data, uid, collection, docId, field, bindingField, signalIdentity)`:
- if `data[field]==nil` return nil; parse envelope; assert `envelope.binding == expectedBinding` (relocation guard); open with local identity private key + expectedBinding.

## Foundation landed (2026-06-05) — VERIFIED

- **`AndroidSignalIdentityKeypair.kt`** — value type (identityKeyId `{deviceId}_{keyVersion}`, public/private serialized libsignal key bytes) + `generate()` via `IdentityKeyPair.generate()` + `asRecipient()`. (Note: libsignal 0.94.4 `ECPrivateKey` is a Kotlin class whose `.publicKey()` does NOT resolve from Kotlin; `IdentityKeyPair.generate()` is the working entry point — its Java getters surface as Kotlin properties.)
- **`AndroidCloudVaultSignalPayloads.kt`** — `signalSealingIsEnabled` (sealingScheme gate + injectable `signalSealingOverrideProvider` test hook), `signalEnvelopeMapIfEnabled` (pure seal to local+peers via `CloudVaultCrypto.sealSignalPayload`), `openSignalPayloadIfPresent` (Signal-first open + relocation guard).
- **`AndroidCloudVaultSignalPayloadsTest.kt`** — **6/6 JVM tests pass** on real libsignal: gate-off-by-default, override toggle, seal round-trips for BOTH local + trusted peer, null-when-gate-off, relocation (wrong docId) rejected, null-when-no-envelope.
- Verify: `cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest --tests 'com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloadsTest' --no-daemon` → BUILD SUCCESSFUL, tests=6 failures=0.

## Persistent store + chat producer LANDED (2026-06-05) — compile + JVM verified

- **`AndroidSignalIdentityKeyStore.kt`** — persistent `loadOrCreate`/`load` (libsignal identity via `AndroidLocalSecretBox` Keystore + SharedPreferences, mirroring `AndroidCloudVaultDeviceKeypair`) + `publishIfNeeded` (client-direct write to `signal_identity_public_keys`, idempotent) + pure `signalIdentityPublicKeyDoc` (rules-parity tested). Made `AndroidLocalSecretBox` `internal` (was `private`) for reuse.
- **`AndroidCloudVaultSignalPayloads.atRestRecipients`** — Firestore resolution of trusted-device Signal identities (excludes local; throws on missing/invalid peer identity, mirroring iOS — activation must publish all identities first).
- **Chat producer wired** (`AssistantChatHistoryStore.kt`): `upsert` dual-writes `signalEnvelope` (gated on `conversations_chat` sealingScheme, identity loaded+published lazily ONLY when gate on → fully inert in production); `decodeThread` is Signal-first with legacy AES-GCM fallback (mirrors iOS exactly: field="signalEnvelope" binding, try/catch fall-through); `fetchAll` threads uid + lazily-loaded local identity.
- **Verified:** `:app:compileDebugKotlin` BUILD SUCCESSFUL; JVM tests `AndroidSignalIdentityKeyStoreTest` 2/2 + `AndroidCloudVaultSignalPayloadsTest` 6/6 + `CloudVaultCryptoTest` 10/10 (regression-clean) + assistants suite green.
- **NOT verified (deferred):** on-device dual-write/read runtime (Firestore + Keystore are instrumented-only; the Galaxy is shared with the Codex agent). This is the activation-time gate — safe because the whole path is fail-closed/inert in production.

## Remaining (next push)

1. **CLI mission producer** (`CLIAgentMissionDispatcher.kt`) — same pattern across buildSealed/sealGroupPayload/initialQueuedEventSealed (writes) + toMissionSnapshot/toMissionEvent (reads) + observe (load identity). Thread localIdentity + atRestRecipients through the static factory methods.
2. **`AndroidSignalIdentityKeyStore.kt`** — DONE (above). (in `android/app/src/main/java/com/openburnbar/data/cloud/`) — generate a libsignal identity keypair, persist private bytes locally (mirror AndroidEscrowDeviceRegistry's storage), expose `identityKeyId` (`{deviceId}_{keyVersion}`) + `publicKeyData` + `privateKeyData`. Publish public key to `users/{uid}/signal_identity_public_keys/{identityKeyId}` (mirror iOS MobileCloudVaultKeyAccess publisher + AndroidEscrowDeviceRegistry.registerSelf).
2. **`AndroidCloudVaultSignalPayloads.kt`** — port the iOS service: `signalSealingIsEnabled(domainID)` (sealingScheme gate + **injectable `signalSealingOverrideProvider` test hook**, matching the iOS pattern), `signalEnvelopeIfEnabled(...)`, `openSignalPayloadIfPresent(...)`, `atRestRecipients(...)`.
3. Wire **AssistantChatHistoryStore.kt** upsert (463) → dual-write `signalEnvelope`; decodeThread (563) → Signal-first open + AES-GCM fallback. Thread signalIdentity through fetchAll→decodeThread.
4. Wire **CLIAgentMissionDispatcher.kt** buildSealed (521) + group + initialQueuedEvent → dual-write; toMissionSnapshot/toMissionEvent (841/885) → Signal-first open + fallback.
5. **JVM unit tests** (mirror `CloudVaultCryptoTest.kt`): gate defaults OFF; with override ON, produces a valid envelope that round-trips; relocation (wrong binding) rejected. No Firestore/device needed (use in-memory identity keypairs as recipients).

## Verification
`cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest --tests 'com.openburnbar.data.cloud.*Signal*' --no-daemon` (gradle cache warmed this session; google-services.json copied into worktree).

## Activation boundary (item 5)
Do NOT set `conversations_chat`/`pensieve` sealingScheme to the signal value in registry.json — that IS the flip. Producers stay dormant; prove "actually producing" only via the `signalSealingOverrideProvider` test hook.
