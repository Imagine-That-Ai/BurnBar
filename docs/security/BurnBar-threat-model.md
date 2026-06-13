# BurnBar Security Architecture and Threat Model

Prepared for: external application security review
Target reviewer: Cure53 or equivalent independent audit firm
Prepared from repository state: `remediation/tech-debt-fable-2026-06-12` at `ba9e7c1486c0`
Date: 2026-06-12

## Evidence Standard

This document describes what the current code supports, not what the product should eventually claim. File and line references are repo-relative implementation pointers from the review checkout. Any audit package sent externally should pin the exact commit and include deployed Firebase Functions, Firestore rules, Storage rules, environment configuration, IAM/KMS policy, and production Remote Config readbacks.

The most important conservative conclusion is this:

BurnBar is not a single universal end-to-end encrypted system. It is a local-first, multi-device agent control system with several sealed or end-to-end encrypted subflows, a Firebase control plane, a trusted-device graph, local endpoint key material, cloud metadata, push providers, hosted provider credentials for selected account types, and powerful local agent runtimes.

## 1. Executive Summary

BurnBar lets users control AI agents running on their own computers from phones, tablets, web clients, and other devices. The architecture includes native iOS, Android, and macOS clients; Firebase Auth, App Check, Cloud Functions, Firestore, Cloud Storage, Secret Manager, and KMS; Hermes Gateway; Iroh device transport; push notifications; local agent runtimes; CloudVault encryption; trusted device enrollment; remote MCP access; and several local or hosted memory/search systems.

The strongest defensible security properties in the current code are:

- Current Hermes Gateway message, event, and attachment writes require sealed relay/ratchet envelopes. New plaintext Gateway writes are rejected in code.
- Gateway HTTP bearer tokens are not sufficient by themselves for active Gateway access. Requests must also prove possession of a client signing key pinned during pairing.
- Current CloudVault-backed conversation, chat, session, mission, and memory payloads use AES-GCM envelopes with path-bound AAD and Firestore rules reject common plaintext fields on current write paths.
- Trusted-device and Computer Use approval flows are guarded by Firebase Auth, App Check attestation binding, high-risk nonces, server-owned trust roots, escrow-device fingerprint binding, Signal identity records, signed action proofs, and transaction state checks.
- Hosted provider credentials are not stored directly in Firestore. The backend stores encrypted envelopes in Secret Manager using KMS-wrapped DEKs, and Firestore stores references.
- Agent reply push notifications use a generic preview rather than message text.

The most important non-claims are:

- BurnBar cannot claim that the cloud sees no data. The cloud sees user IDs, device IDs, client IDs, destination IDs, timestamps, counters, statuses, sizes, ciphertext hashes, search token/semantic hashes, usage/billing facets, entitlements, push tokens, routing metadata, and hosted provider secret references.
- BurnBar cannot claim all communication uses Signal or full end-to-end encryption. Signal v4 Gateway writes are present in code as a read-tolerant/staged path, but production Gateway Signal writes are disabled unless the production Signal envelope version set is explicitly configured.
- BurnBar cannot claim full forward secrecy. The relay crypto documents limited forward secrecy for the ephemeral leg and explicitly notes no static-leg PFS and no KCI protection for that scheme.
- BurnBar cannot protect plaintext from compromised endpoints or compromised local agent runtimes. Phones, Macs, Android devices, and local agents necessarily see plaintext before sealing or after opening.
- BurnBar cannot claim provider credentials are zero-knowledge for hosted/cloud-refreshable provider accounts. Backend service accounts with the right KMS and Secret Manager permissions can decrypt those credentials.
- BurnBar cannot yet claim all historical data is scrubbed of plaintext without production backfill evidence.

Audit verdict: BurnBar has meaningful and code-backed controls for sealed current-write paths, trusted-device gating, Gateway PoP authentication, and encrypted at-rest mirrors. The high-risk residual surfaces are endpoint compromise, local agent privilege, admin/IAM/KMS access, metadata leakage, legacy plaintext/backfill state, deployment/config drift, and any deployed realtime relay or fallback paths not pinned by this review.

## 2. System Overview

### Architecture Diagram

```text
                              +----------------------+
                              |  External Providers  |
                              |  AI APIs / quota APIs |
                              +----------+-----------+
                                         |
                                         | hosted credentials, API calls
                                         v
+-------------+     Auth/AppCheck  +-----+------------------------------+
| iOS/iPadOS  |------------------->| BurnBar Cloud / Firebase Functions |
| Android     |                    | - Hermes Gateway callables/HTTP     |
| Web/MCP     |<-------------------| - CloudVault/search/session APIs    |
| clients     | sealed payloads,   | - trusted device/grant APIs         |
+------+------+ tokens, metadata   | - push/provider/entitlement APIs    |
       |                           +-----+---------+---------+-----------+
       |                                 |         |         |
       |                                 |         |         |
       |                                 v         v         v
       |                         +-------+--+  +---+---+  +--+-----------+
       |                         |Firestore|  |Storage|  |Secret Manager |
       |                         | rules   |  | rules |  | + Cloud KMS   |
       |                         +----+----+  +---+---+  +--+-----------+
       |                              |           |         |
       |                              | metadata, | sealed  | provider
       |                              | sealed    | blobs   | credentials
       |                              | docs      |         |
       |                              v           v         |
       |                         +----+-----------+---------+---+
       |                         | APNs / FCM / notification     |
       |                         | delivery and push token store |
       |                         +-------------------------------+
       |
       | sealed Gateway events/messages, Iroh records, direct/local transport
       v
+------+---------------------------------------------------------------+
| macOS OpenBurnBar / AgentLens                                       |
| - CloudVault key access and local Keychain                          |
| - Hermes/Iroh pairing and relay sender keys                         |
| - local logs, memories, search indexes                              |
| - CLI bridge and managed agent runtimes                             |
| - privileged daemon socket for system actions where enabled          |
+------+---------------------------------------------------------------+
       |
       | local process execution, stdout/stderr, filesystem, provider state
       v
+------+---------------------------------------------------------------+
| Local Agent Runtimes and Desktop System                             |
| Claude / Codex / Droid / Forge / Cursor Agent / provider CLIs        |
| User filesystem, browser/provider credential stores, local memory     |
+----------------------------------------------------------------------+
```

### Major Components

| Component | Purpose | Data handled | Trust level | Dependencies | Evidence |
|---|---|---|---|---|---|
| Mobile iOS/iPadOS app | User-facing remote control, Hermes Gateway client, CloudVault client, trusted device, push receiver | Message plaintext before sealing/after opening, vault keys, device private keys, push tokens, approvals, attachments | High trust endpoint | Firebase Auth/App Check, iOS Keychain, APNs, CloudVault, Hermes/Iroh | `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift`, `OpenBurnBarMobile/Services/iOSDeviceKeypair.swift` |
| Android app | Mobile client parity for chat, CloudVault, trusted device, push, media | Message plaintext, vault keys, Android private keys, FCM tokens, approvals | High trust endpoint | Firebase, Android Keystore, Firestore, FCM | `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt` |
| macOS OpenBurnBar / AgentLens | Desktop host for local agents, Hermes/Iroh endpoint, local memory/indexing, device trust root publisher | Agent prompts/responses, local files/logs, key material, provider metadata, runtime output | High trust endpoint | macOS Keychain, local process APIs, Firebase, Iroh, Hermes | `AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift`, `AgentLens/Services/CloudVaultKeyAccess.swift` |
| OpenBurnBarCore | Shared crypto, sealed envelopes, Iroh pairing, CloudVault types, Signal at-rest helpers | Crypto envelopes, AAD, key wrapping primitives, pairing records | Security-critical shared library | CryptoKit, Swift shared models, Android-compatible formats | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift`, `CloudVaultCrypto.swift`, `OpenBurnBarSignalCore/SignalAtRestSealer.swift` |
| BurnBar Cloud / Firebase Functions | Authenticated control plane, Gateway HTTP/callables, push fanout, provider secrets, search/session APIs, entitlement checks | Auth context, metadata, sealed payloads, provider secret refs, push requests, audit events | Trusted service, not plaintext-blind for all data | Firebase Auth, App Check, Firestore, Storage, Secret Manager, KMS, APNs, FCM | `functions/src/index.ts`, `functions/src/auth.ts`, `functions/src/logging.ts` |
| Firestore | Primary control-plane and sync database | Sealed documents, metadata, indexes, device records, trust roots, tokens, audit events | Trusted storage for metadata; untrusted for sealed content confidentiality | Firestore rules, Functions Admin SDK | `firestore.rules` |
| Cloud Storage | Encrypted session blobs, attachment objects, profile photos | Sealed blobs and some public/auth-visible profile photos | Trusted storage for availability and object metadata; untrusted for sealed content confidentiality | Storage rules, signed URLs | `storage.rules`, `functions/src/callables/encryptedSearch.ts` |
| Hermes Gateway | Phone/cloud/Mac Gateway for paired devices and agent replies | Sealed Gateway events/messages/attachments, metadata, bearer token hashes, client signing keys | Trusted relay/control plane, content-blind for current sealed writes | Firebase Functions, Firestore, Storage, client relay keys | `functions/src/hermesGateway.ts`, `functions/src/callables/hermesGateway.ts` |
| Iroh relay/direct transport | Device-to-device transport and endpoint discovery | Length-prefixed frames, pairing records, endpoint addresses, node IDs | Transport layer should not inspect frame contents; endpoint identity matters | Iroh, Keychain, Firestore pairing directory | `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayTransport.swift`, `IrohRelayPairing.swift` |
| Hermes realtime relay / WSS fallback | Possible fallback relay path for realtime transport | Realtime frames and routing metadata if deployed | Deployment status needs confirmation | `services/hermes-realtime-relay`, Gateway fallback flags | `services/hermes-realtime-relay/`, audit event names such as `iroh_fallback_to_wss` |
| Local agent runtimes | Execute model CLIs or managed runtimes on the user's Mac | Prompts, responses, tool output, local filesystem access, environment variables | High-risk local execution surface | macOS process APIs, user PATH/config, local files | `AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift`, `AgentLens/Services/ManagedAgentRuntime/ManagedRuntimeProcessRunner.swift` |
| OpenBurnBarDaemon / privileged helpers | Local system actions, remote unlock, privileged socket boundary | Credential envelopes, HID/system actions, socket peer identities | Very high trust local component | macOS code signing, Unix sockets, Keychain, HPKE | `OpenBurnBarDaemon/.../PrivilegedPeerAuthenticator.swift`, `OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift` |
| CloudVault and trusted-device key management | At-rest sealing and cross-device vault-key wrapping | Vault keys, wrapped vault keys, escrow keys, device trust records, Signal identity bindings | Security-critical client/server boundary | Keychain/Keystore, Firestore rules, high-risk callables | `CloudVaultCrypto.swift`, `CloudVaultKeyAccess.swift`, `computerUseSecurity.ts`, `firestore.rules` |
| Signal directory and at-rest Signal helpers | Publish public identity/prekey material and seal at-rest payloads to recipient devices | Public Signal keys, at-rest envelopes, sender signatures, recipient wraps | Security-critical but production Gateway Signal status is staged/flagged | Firestore rules, client identity keys | `SignalAtRestSealer.swift`, `SignalEnvelopeAAD.swift`, `firestore.rules` |
| Provider credential store | Hosted/cloud-refreshable account connection and quota refresh | API credentials, Secret Manager resource names, provider account metadata | Backend-trusted; not E2EE | Secret Manager, Cloud KMS, provider APIs | `functions/src/secrets.ts`, `functions/src/callables/providerAccounts.ts` |
| Notification service | Agent reply, call, VoIP, and Android push fanout | Push tokens, event IDs, thread IDs, call IDs, caller/display metadata | Trusted metadata service; third-party push providers see payloads | APNs, FCM, Firestore | `functions/src/agentNotifications.ts`, `functions/src/callables/voipPush.ts`, `functions/src/apnsSender.ts`, `functions/src/fcmAndroidSender.ts` |
| Hosted MCP / remote access | Remote MCP grants, hosted search facade, local decrypt shim mode | OAuth-style grants, access/refresh tokens, scopes, encrypted search results, audit logs | High-risk remote access control plane | HMAC token service, Firebase Admin, local Keychain shim | `functions/src/callables/remoteMcp.ts`, `functions/src/remoteMcpOAuth.ts`, `services/hosted-mcp/src/` |
| Entitlements and billing | Gate Pro/paid capabilities and high-risk flows | Subscription state, account IDs, purchase/Stripe metadata | Trusted business-control plane | Store APIs, Stripe, Firestore | `functions/src/index.ts`, entitlement helper usage across callables |

## 3. Significant Data Flows

| Flow | Sender -> Receiver | Transport | Authentication | Encryption | Plaintext in transit | Plaintext at rest | Evidence and notes |
|---|---|---|---|---|---|---|---|
| Firebase callable access | Client -> Functions | HTTPS callable | Firebase Auth; App Check via `enforceAuthAndAppCheck`; entitlement checks on gated APIs | TLS | Yes at client and function handler for non-sealed request fields | Depends on handler; many writes sealed, some metadata plaintext | `functions/src/auth.ts:22-72`, `functions/src/config.ts:68-106` |
| High-risk Computer Use action | Trusted device -> Functions -> Firestore | HTTPS callable and Admin SDK write | Auth, App Check attestation binding, high-risk nonce, trusted-device signed action proof | TLS plus signed proof; payload may be sealed depending on action | Approval metadata plaintext to Functions | Firestore stores status, device IDs, audit metadata; sealed mission fields where required | `appCheckAttestation.ts:98-253`, `computerUseSecurity.ts:793-860`, `firestore.rules:1330-1568` |
| CloudVault conversation/chat/CLI sync | Client -> Firestore | Firestore SDK or Functions | Auth/App Check and rules | Client-side AES-GCM sealed payloads with AAD for current schema | Plaintext exists on endpoint before seal | Current payload ciphertext at rest; metadata visible | `CloudVaultCrypto.swift:428-622`, `firestore.rules:1167-1328` |
| CloudVault key wrapping | Trusted source device -> Firestore -> target device | Firestore SDK/callables | Auth/rules; trusted escrow device requirements | Vault key wrapped to target device public key | Vault key plaintext exists on source and target endpoints | Wrapped key blobs and device metadata at rest | `CloudVaultKeyAccess.swift:172-358`, `MobileCloudVaultKeyAccess.swift:170-388`, `firestore.rules:2153-2198` |
| Hermes Gateway device pairing | Agent/Mac -> Functions; phone approves -> Functions | HTTPS callables | Auth/App Check; device/user codes; entitlement; client signing key; relay public keys | TLS; later sealed relay keys; bearer token hash stored | Pairing metadata and public keys visible | Active client/destination records, token hashes, public keys, scopes | `callables/hermesGateway.ts:884-982`, `1769-1925` |
| Hermes Gateway phone-to-agent event | Phone/client -> Gateway Functions -> Firestore -> agent | HTTPS/Firestore listener | Bearer token plus PoP signing key; Auth/App Check for callable events | Relay v2/v3 envelope or ratchet envelope; Signal v4 read-tolerant but production writes disabled | Plaintext on sender and recipient endpoints only for current sealed writes | Ciphertext envelope and metadata at rest | `hermesGateway.ts:83-153`, `691-817`, `callables/hermesGateway.ts:2206-2390` |
| Hermes Gateway agent reply | Agent/Mac -> Gateway Functions -> Firestore -> phone | HTTPS HTTP route | Bearer token plus PoP; active client/destination; replay/sequence checks | Relay/ratchet envelope; plaintext `text` rejected for new writes | Plaintext on agent and phone only for current sealed writes | Ciphertext envelope plus sequence/status metadata | `callables/hermesGateway.ts:810-865`, `1116-1193` |
| Hermes attachment upload | Client -> signed URL -> Storage; finalize -> Functions/Firestore | HTTPS signed URL and callable | Gateway bearer plus PoP to initialize/finalize; signed URL for upload | Attachment bytes sealed before upload; manifest envelope seals filename/content type/byte count | Plaintext on endpoint only | Ciphertext object at rest; size, path, ciphertext hash, status visible | `callables/hermesGateway.ts:1409-1605` |
| Iroh pairing record publication | Mac -> Functions/Firestore -> mobile | HTTPS callable and Firestore read | Trusted macOS escrow device; high-risk callable; signed record | Record is public identity/routing data, not secret | Public endpoint metadata visible | Pairing public key, signed endpoint record, direct addresses/relay URL visible | `IrohPairingPublicKeyPublisher.swift:11-37`, `IrohRelayPairing.swift:5-169`, `computerUseSecurity.ts:1592-1708` |
| Iroh frame transport | Device <-> device/relay | Iroh direct or relay transport | Endpoint key and signed pairing record verification | Transport frames should carry app-level sealed payloads where required | Transport does not inspect, but endpoint plaintext exists | Not stored by transport unless higher layer logs/stores | `IrohRelayTransport.swift:4-98` |
| Encrypted session blob upload/download | Client -> Storage/Firestore -> client | Functions-signed URL and Firestore metadata | Auth/App Check, entitlement, path validation | Client-side AES-GCM blob; Storage content type octet-stream | Plaintext on endpoint only | Ciphertext blob and search/index metadata at rest | `encryptedSearch.ts:52-144`, `shared.ts:513-580`, `storage.rules:5-13` |
| Encrypted search index | Client -> Firestore; query -> Functions | HTTPS callable/Firestore | Auth/App Check and entitlement | Sealed previews/snippets; token/semantic hashes are plaintext indexes | Query plaintext/token derivation on endpoint; Functions receive keyed hashes | Hashes, facets, counts, sealed previews/snippets at rest | `encryptedSearch.ts:146-907`, `conversationQuery.ts:132-163` |
| Project memory snapshot | Client -> Functions/Firestore -> client | HTTPS callable | Auth/App Check and entitlement | Sealed snapshot with opaque vault-key-derived document ID | Plaintext on endpoint | Sealed snapshot, content-free facets, opaque ID at rest | `encryptedSearch.ts:364-568` |
| Hosted provider credential storage | Client -> Functions -> Secret Manager/KMS | HTTPS callable; server KMS calls | Auth/App Check, entitlement; provider adapter validation | TLS to Functions; Secret Manager envelope encrypted with KMS | Credential plaintext exists in function memory during validation/storage | Secret encrypted in Secret Manager; Firestore stores secret ref and provider metadata | `providerAccounts.ts:43-249`, `secrets.ts:1-263`, `shared.ts:1465-1607` |
| Agent reply notification | Functions -> APNs/FCM -> device | APNs/FCM | Server credentials; push token | Provider transport encryption only | Notification metadata visible to BurnBar and push provider | Notification event metadata in Firestore; generic preview avoids reply text | `agentNotifications.ts:21-327` |
| VoIP/call push | Client -> Functions -> APNs/FCM | HTTPS callable and APNs/FCM | Auth/App Check, entitlement, push token resolution | Provider transport encryption only | Call metadata visible to BurnBar and push provider | Outbound push request metadata retained in queue/audit docs | `callables/voipPush.ts:14-113`, `voipPush.ts:42-104` |
| Local agent runtime invocation | macOS app -> local process -> macOS app | Local process pipes | Local OS user session; app process control | None at process pipe layer | Yes, prompts/responses/stdout/stderr plaintext locally | Local logs/memory may store plaintext before CloudVault sealing | `CLIProcessStreamRunner.swift:8-250`, `ManagedRuntimeProcessRunner.swift:22-66` |
| Privileged daemon IPC | App -> Unix socket daemon | Local Unix socket | UID check, code-signing Team ID, exact bundle IDs, hardened runtime/library validation | Remote Unlock uses HPKE credential envelope; socket itself local | Credential plaintext only at intended endpoint after open | Depends on daemon logs/storage; signed/audited actions | `PrivilegedPeerAuthenticator.swift:14-84`, `PrivilegedSocketTrust.swift:15-204`, `RemoteUnlockCredentialEnvelopeCrypto.swift:5-122` |
| Remote MCP grant/search | User/client -> Functions/hosted MCP -> local decrypt shim or Firestore | HTTPS MCP server | HMAC access token, refresh token, scopes, Pro entitlement, rate limit | TLS; default search cannot derive CloudVault trapdoors without local shim | Hosted server sees request metadata and supplied hashes, not vault key by default | Grant/token hashes, audit events, encrypted search results | `remoteMcp.ts:18-128`, `remoteMcpOAuth.ts:23-100`, `services/hosted-mcp/src/auth.ts:83-152`, `tools/openburnbar-mcp-remote/src/vaultStore.ts:32-68` |

## 4. Trust Boundaries

| Boundary | Assumptions | Compromise impact | Key controls | Residual risk |
|---|---|---|---|---|
| Endpoint device <-> BurnBar Cloud | The endpoint OS, app binary, local key storage, and user session are not compromised; deployed Auth/App Check/rules match repo | Attacker can submit user-authorized actions, sync malicious ciphertext, read metadata, or abuse grants; endpoint compromise exposes plaintext | Firebase Auth, App Check, Firestore rules, signed action proofs, high-risk nonces, sealed payloads | Endpoint compromise remains outside the cryptographic protection boundary |
| BurnBar Cloud <-> Firestore/Storage | Firestore/Storage enforce current rules; Functions Admin writes are correct; IAM limits admin access | Direct data tampering, metadata exposure, deletion, denial of service, legacy plaintext exposure | Rules restrict direct client writes; server-owned trust roots; create-if-absent transactions; Storage size/path checks | Admin SDK bypasses rules; production deployment drift can invalidate assumptions |
| BurnBar Cloud <-> Secret Manager/KMS | Only intended service accounts can decrypt hosted provider secrets; KMS audit logs are monitored | Rogue admin or compromised service account can decrypt provider credentials and refresh tokens | Secret Manager envelope encryption with KMS; Firestore only stores refs | Not zero-knowledge; IAM/KMS review is required |
| Phone/client <-> Hermes Gateway <-> Mac/agent | Pairing keys are pinned; bearer token is secret; PoP key remains on paired client; new writes are sealed | Spoofed messages, malicious agent commands, replay, metadata exposure | Bearer+PoP auth, token hash, active client state, relay v2/v3 envelopes, replay/sequence checks, no new plaintext writes | Metadata remains visible; compromised endpoint or PoP private key can act as that client |
| Device <-> Device over Iroh/direct/relay | Pairing records are signed and fresh; node identity keys remain private; app frames are sealed where needed | Endpoint replacement, relay downgrade/fallback abuse, traffic DoS | Server-owned pairing public keys, signed records, freshness checks, Keychain keys | WSS fallback/realtime relay deployment status needs external verification |
| App <-> Keychain/Keystore | OS key storage protects private keys and vault keys from other local users/processes; device unlock state is trustworthy | Theft of vault key, device identity key, relay key, provider local secrets | Keychain `WhenUnlockedThisDeviceOnly`; Android Keystore AES-GCM local secret box | Malware running as user may access plaintext via app or local process surfaces |
| User <-> agent runtime | The selected agent runtime follows user intent and does not exfiltrate local data; prompts/tool outputs are trustworthy enough for the grant | Prompt injection, filesystem exfiltration, command abuse, forged output | Capability grants, local approvals, audited mission approvals, runtime allowlists | No hard process sandbox is evident in the reviewed process runners |
| App <-> privileged daemon/system input | Only first-party signed apps can connect; daemon validates peer identity; credential envelopes bind request context | Unauthorized HID/system actions, credential misuse, remote unlock abuse | UID, code signature, exact bundle IDs, hardened runtime/library validation, HPKE credential envelopes | Signed app compromise or local privilege escalation compromises this boundary |
| BurnBar <-> APNs/FCM | Push providers deliver only intended payloads; push tokens are current; payloads are minimal | Push metadata disclosure, push spoofing through server compromise, notification DoS | Generic agent reply preview, token lifecycle handling, provider credentials server-side | Call/VoIP metadata and display names are visible to BurnBar and push providers |
| BurnBar <-> provider APIs | Provider credentials are valid and stored according to account mode; provider API responses are trusted for quota/status | Credential theft, forged quota data, provider account takeover | Provider adapter validation, Secret Manager/KMS storage, local-only mode option | Hosted provider credentials are backend-decryptable |
| Hosted MCP <-> local decrypt shim | Default hosted path cannot derive vault trapdoors; local shim controls vault key; grants/scopes are limited | Bearer token theft, overbroad MCP scopes, cloud-side search metadata exposure | Short-lived HMAC access tokens, hashed refresh tokens, scopes, Pro entitlement, rate limits | Remote-readable explicit opt-in mode must be separately audited before broad claims |
| Operator/admin <-> production project | Admin access is limited, logged, and used only through approved procedures | Rules/config bypass, KMS decrypt, deletion, backfill mistakes, function config weakening | IAM, audit logs, deployment pipelines, config defaults that fail closed in production-looking projects | Needs external IAM/KMS/deploy evidence, not just code review |

## 5. Asset Inventory

| Asset | Value | Confidentiality requirement | Integrity requirement | Availability requirement | Notes |
|---|---:|---|---|---|---|
| Message plaintext and agent prompts/responses | Critical | Only intended endpoints and local runtimes should see plaintext | Must not be modified without detection before display/execution | High for active agent workflows | Endpoint compromise defeats confidentiality |
| Attachments and attachment filenames | Critical | Bytes and manifest fields should be sealed before cloud upload | Manifest/body binding and size/hash checks must detect tamper | Medium/high | Size, path, status, ciphertext hash remain metadata |
| CloudVault vault key | Critical | Must remain endpoint-local or wrapped only to trusted devices | Wrong vault key must not be accepted as current key | Critical for encrypted sync recovery | Backend stores state and wrappers, not plaintext key |
| Device escrow private keys | Critical | Must remain in Keychain/Keystore/Secure Enclave/StrongBox where available | Must sign/decrypt only for intended device identity | Critical for device trust and recovery | Android path uses Android Keystore local secret box, not necessarily StrongBox/user-auth |
| Signal identity/prekey/session material | Critical | Private/session/ratchet state must never be written to Firestore | Public identity binding must match trusted device/key version | High for sealed at-rest and future transport flows | Firestore rules explicitly forbid private/session/ratchet state fields in directory docs |
| Hermes Gateway bearer token and PoP private key | Critical | Token and signing private key must remain client-local | Requests must bind to pinned client key and active scope | High for Gateway usability | Bearer alone is insufficient, but token+PoP compromise impersonates client |
| Relay sender private keys | Critical | Must remain on sending device | Pinned public key and Signal identity binding must be enforced | High | Used for v3 authenticated relay request opening |
| Iroh endpoint and pairing private keys | Critical | Must remain in Keychain/local device | Pairing signatures and freshness must verify endpoint records | High for direct/local transport | Keychain save failure can lead to ephemeral fallback/rotation |
| Provider API credentials | Critical | Hosted mode secrets must be limited to backend and Secret Manager/KMS | Wrong provider binding or secret ref must be rejected | Medium/high for quota and provider features | Not E2EE; backend can decrypt with IAM/KMS access |
| Computer Use approvals and grants | Critical | Approval contents may include sensitive mission data and must be sealed where required | Approval status must not be forgeable or replayable | High for safe remote control | Some capability names and statuses are metadata |
| Remote MCP grants/tokens | Critical | Access/refresh tokens must not leak; refresh tokens stored hashed | Scope/client/sub/audience must be enforced | Medium/high | Access token theft works until expiry |
| Local agent memory, session logs, project memory | High | Content should be sealed before cloud sync; local plaintext is endpoint-trusted | Search index and sealed body hashes must bind to content | Medium/high | Search hashes/facets leak metadata/access patterns |
| Push tokens and call metadata | High | Tokens should be user-scoped; call metadata minimized | Token ownership and invalidation must be correct | High for notifications/calls | Push providers see payloads |
| User metadata and routing metadata | High | Minimize exposure to cloud/admins; not content-confidential | Must not be forgeable across users/devices | High for sync/routing | Includes IDs, timestamps, sizes, statuses, counters, provider/model facets |
| Billing and entitlement records | Medium/high | Account/subscription data limited to backend/admins | Entitlement checks must not be bypassed | High for feature gating | Used as security gate for some high-risk flows |
| Audit logs | Medium/high | Must not contain secrets/plaintext; admin visibility controlled | Append-only or tamper-evident where possible | High for investigations | Logging scrubber exists but cannot prove all future fields safe |
| Profile photos | Medium | Current Storage rules allow any authenticated read | Must be owner-written and size/type constrained | Medium | Not private under current rules |

## 6. Adversary Model

### External unauthenticated attacker

Capabilities: Internet access to public Functions endpoints, ability to guess device/user codes, attempt replay, flood public endpoints, upload to signed URLs if obtained.

Limitations: No Firebase Auth session, no App Check token, no Gateway bearer+PoP key, no trusted device private keys.

Motivation and realistic paths:

- Pairing-code guessing or device-start flooding.
- Trying to exploit HTTP Gateway auth ordering, token hashes, or replay caches.
- Abuse of public-ish endpoints through rate-limit gaps.

Relevant controls: Auth/App Check, rate limits, short TTL pairing sessions, PoP requirement before entitlement leakage, create-if-absent writes.

### Malicious authenticated user

Capabilities: Valid account, valid App Check client, ability to write own-user Firestore docs permitted by rules, attempt to forge metadata, create many objects, abuse entitlements.

Limitations: Cannot directly write server-owned trust roots, other users' documents, or hosted provider secrets without server callables.

Motivation and realistic paths:

- Cost exhaustion through Storage/Firestore writes.
- Attempting to promote an untrusted device or publish bogus Iroh/relay keys.
- Attempting cross-user reads or writes by manipulating user IDs.

Relevant controls: ownership rules, server-owned trust roots, high-risk nonces, entitlement gates, size caps, bounded schemas.

### Stolen Firebase session or malicious same-user client

Capabilities: Acts as the user through Auth; may pass App Check if running on a real app/device; can call user-scoped APIs.

Limitations: Should not have trusted-device private keys, vault key, PoP keys, or high-risk nonces unless also on a trusted device/app context.

Motivation and realistic paths:

- Read user metadata and sealed ciphertext.
- Attempt to create pending devices, queue grants, or write encrypted garbage.
- Abuse any callable that lacks the stronger trusted-device proof layer.

Relevant controls: App Check attestation binding, high-risk nonce, trusted-device action proof, server-owned trust roots. Residual risk remains for user-scoped metadata and denial of service.

### Network attacker

Capabilities: Observe, block, replay, or modify network traffic between endpoints and cloud/relays.

Limitations: TLS protects HTTPS; sealed envelopes protect message/attachment content where correctly used.

Motivation and realistic paths:

- Traffic analysis and availability attacks.
- Replay of captured Gateway messages or high-risk action requests.
- Downgrade attempts to legacy/plaintext envelope versions.

Relevant controls: TLS, AES-GCM/HPKE AAD, relay version restrictions for production writes, replay caches, nonce expiry, signed pairing records. Traffic metadata leakage remains.

### Compromised endpoint or local malware

Capabilities: Read local plaintext, interact with app UI, read stdout/stderr, steal keys from process memory, access user files, invoke local agents, potentially access Keychain through user session.

Limitations: Cannot directly decrypt other endpoints' content unless keys/wrappers are present or device is trusted.

Motivation and realistic paths:

- Exfiltrate messages before seal/after open.
- Steal vault key, relay keys, PoP private keys, provider local credentials.
- Approve Computer Use or agent grants as the user.

Relevant controls: OS key storage, local authentication where implemented, trusted-device proofs, audit logs. This is the primary residual risk because endpoint plaintext is intentionally in scope.

### Malicious or compromised local agent runtime

Capabilities: Process launched by the macOS app with local user privileges, can emit arbitrary stdout/stderr, may read accessible files depending on runtime/tooling, may perform actions allowed by grants.

Limitations: Bound by OS permissions and any product grant enforcement; cannot break cloud crypto without local keys.

Motivation and realistic paths:

- Prompt injection leading to local file disclosure.
- Command/tool abuse under broad grants such as shell or desktop system input.
- Forged output or hidden exfiltration through model/provider channels.

Relevant controls: Capability presets/grants, local approvals, runtime allowlists, audit. No reviewed hard process sandbox means this should be audited as a major boundary.

### Compromised BurnBar cloud service or rogue administrator

Capabilities: Read/write Firestore and Storage metadata, deploy modified Functions/rules, access Secret Manager/KMS depending on IAM, delete data, weaken config, issue Admin SDK writes.

Limitations: Should not decrypt correctly sealed message/attachment bodies without endpoint/vault keys, assuming code and clients are uncompromised.

Motivation and realistic paths:

- Read metadata and encrypted blobs.
- Decrypt hosted provider credentials if IAM permits.
- Push malicious config/rules/functions or trust-root records.
- Delete or corrupt user data.

Relevant controls: Client-side crypto for sealed content, KMS/IAM, audit logging, deployment controls. This boundary requires external production evidence.

### Stolen physical device

Capabilities: Possession of phone/Mac/Android device, possible unlocked session or biometric/passcode attack.

Limitations: Keychain/Keystore should protect keys while locked depending on platform settings.

Motivation and realistic paths:

- Use app session to read plaintext.
- Approve device trust/grants or access vault key if unlocked.
- Extract local logs and unsealed cache.

Relevant controls: Keychain `WhenUnlockedThisDeviceOnly`, Android Keystore wrapping, trusted-device proofs. Device lock/local auth policy needs explicit review.

### Push provider or push-token observer

Capabilities: See push payloads and timing; deliver, delay, or drop notifications; token compromise.

Limitations: Should not see sealed message bodies for agent replies.

Motivation and realistic paths:

- Infer communication patterns, call events, thread IDs, call IDs, display names.

Relevant controls: Generic agent reply preview; payload minimization. VoIP/call metadata remains visible.

### Supply chain or update compromise

Capabilities: Malicious app binary, dependency, build pipeline, or release artifact.

Limitations: Outside direct runtime controls if user installs compromised binary.

Motivation and realistic paths:

- Exfiltrate endpoint keys/plaintext.
- Disable sealing or upload plaintext.
- Modify privileged daemon or local runtime.

Relevant controls: Code signing, hardened runtime checks for local daemon IPC, CI/release controls. Requires separate supply-chain audit.

## 7. Threat Analysis (STRIDE)

The table below is organized around realistic component/data-flow threats rather than enumerating every file path. Likelihood is relative for a production consumer app with Internet-facing Firebase endpoints and local agent runtimes.

### Spoofing

| Threat | Preconditions | Impact | Likelihood | Existing mitigations | Residual risk |
|---|---|---|---:|---|---|
| Impersonate a Hermes Gateway client with a stolen bearer token | Attacker obtains bearer token but not client signing key | Send/receive Gateway messages or enumerate scope if accepted | Medium | Gateway requires token hash match, active client, expiry check, and PoP signature before entitlement/scope handling | Token plus PoP private key compromise fully impersonates the client |
| Replace an Iroh endpoint record | Attacker can write or influence pairing directory | Phone dials attacker endpoint or relays to attacker | Medium | Pairing public keys/records are server-owned through high-risk callables; records are signed and freshness-limited | Direct deployment/rules drift or trusted Mac compromise can publish bad records |
| Promote an attacker device to trusted | Attacker has user Auth session and a pending device | Device can receive vault wrappers or approve high-risk actions | High impact, medium likelihood | High-risk nonce, App Check attestation binding, escrow fingerprint enforcement, trusted native approver signature, Signal identity binding | Bootstrap/first-device flows and stolen unlocked trusted device remain sensitive |
| Spoof remote MCP access | Attacker obtains grant access token | Query hosted MCP within token scope | Medium | HMAC tokens with audience/sub/client/scope/expiry checks; query-string token rejected; refresh token hashed | Bearer access token valid until expiry; broad scopes or explicit remote-readable mode increase impact |
| Spoof privileged daemon client | Attacker runs local process and connects to Unix socket | Unauthorized system/credential action | Low/medium | UID, audit token, Team ID, exact bundle ID, designated requirement, hardened runtime, library validation | Compromised signed app or local privilege escalation bypasses this boundary |

### Tampering

| Threat | Preconditions | Impact | Likelihood | Existing mitigations | Residual risk |
|---|---|---|---:|---|---|
| Modify sealed message or attachment ciphertext in Firestore/Storage | Attacker can write or alter stored ciphertext | Message corruption, failed decrypt, possible UI confusion | Medium | AES-GCM/HPKE authentication, AAD binds uid/connection/request/path fields, attachment finalize checks size/hash/path/status | Tampering can still cause denial of service |
| Clobber an existing Gateway message/event/attachment | Attacker can replay or race an ID | Replace old message or attach wrong body | Medium | Create-if-absent transactions and sequence checks; replay caches for authenticated relay | Endpoint compromise can generate valid new content |
| Write plaintext fields through direct Firestore access | Malicious client writes own docs | Cloud stores plaintext message/project/session fields | Medium | Rules reject common plaintext fields for current conversation, chat, CLI, mission, Gateway schemas | Legacy docs/backfill and unreviewed collections need production scan |
| Tamper with trusted-device or key-root records | Malicious client writes Firestore trust roots | Device trust graph corruption | High impact, low likelihood | Many trust-root collections are server-owned; clients use callables with proof checks | Admin SDK/IAM compromise bypasses rules |
| Local agent modifies plaintext before sealing | Agent runtime is malicious or prompt-injected | Incorrect commands/responses sealed as if legitimate | Medium/high | Grants/approvals/audit and runtime restrictions | Crypto cannot distinguish malicious local plaintext from legitimate endpoint-generated plaintext |

### Repudiation

| Threat | Preconditions | Impact | Likelihood | Existing mitigations | Residual risk |
|---|---|---|---:|---|---|
| User/device denies approving a mission or grant | Approval was made from a trusted device | Disputed high-risk action | Medium | Signed trusted-device action proof, approvedByDeviceId, nonce, Firestore audit events, transaction state | If device was stolen/unlocked or malware used app context, attribution to human intent is weaker |
| Agent denies producing an output/action | Local runtime generated stdout/tool action | Investigation uncertainty | Medium | Process registry and local/cloud audit events where present | Local logs may be controlled by compromised endpoint; not cryptographic nonrepudiation |
| Provider credential change is disputed | User or attacker connects/deletes provider account | Account takeover or loss of quota refresh | Medium | Auth/App Check, provider validation, audit logging where present | Need complete audit-log coverage review for all provider lifecycle paths |

### Information Disclosure

| Threat | Preconditions | Impact | Likelihood | Existing mitigations | Residual risk |
|---|---|---|---:|---|---|
| Cloud reads current Hermes message bodies | Cloud/operator has Firestore/Functions access but not endpoint keys | Disclosure of message content | Low for current sealed writes | New writes require relay/ratchet envelopes; plaintext Gateway grace is closed; server validates shape and does not decrypt | Metadata visible; compromised endpoint or modified client can leak plaintext |
| Cloud reads CloudVault conversation/session/project memory bodies | Cloud/operator has Firestore/Storage access but not vault key | Disclosure of synced content | Low/medium for current schema | AES-GCM sealed payloads with AAD; rules reject plaintext fields; Storage stores octet-stream sealed blobs | Search hashes/facets and legacy docs may leak; production backfill evidence required |
| Cloud/admin decrypts hosted provider credentials | Rogue admin or service account has KMS/Secret Manager access | Provider account compromise | Medium | Secret Manager envelope encryption and Firestore secret refs | This is backend-decryptable by design, so IAM/KMS is the actual boundary |
| Push provider sees sensitive payload | Push sent through APNs/FCM | Metadata disclosure | Medium | Generic agent reply preview avoids reply text | VoIP/call payloads include call IDs, connection IDs, paired device IDs, display names/caller names |
| Search index leaks content through hashes/facets/access patterns | Attacker/admin sees Firestore indexes or query logs | Partial inference about user activity/content | Medium | Keyed token/semantic hashes and sealed snippets/previews | Hash frequency, provider/model/device/time/cost/source facets remain metadata |
| Profile photos disclosed to other authenticated users | Any authenticated user reads profile photo path | Privacy exposure | Medium | Owner-only writes, size/content-type constraints | Storage rules allow authenticated reads for profile photos |
| Logging leaks secrets/plaintext | Error/log path contains sensitive fields not caught by scrubber | Secret disclosure to logs/Sentry | Medium | Structured logging scrubber for secret-like keys, long-value truncation, Sentry capture wrapper | Scrubber is pattern-based; arbitrary error strings or new fields can bypass intent |

### Denial of Service

| Threat | Preconditions | Impact | Likelihood | Existing mitigations | Residual risk |
|---|---|---|---:|---|---|
| Pairing/device-start flood | Internet attacker or malicious user hits public pairing endpoints | Exhaust quotas, spam pending sessions | Medium/high | Public IP/device-hash rate limits, short pending-session TTL, user-code flow | Distributed attacks and Firebase cost exhaustion remain possible |
| Storage/ciphertext object abuse | Attacker obtains signed upload URL or abuses own account | Storage cost or stuck attachment state | Medium | Signed URL expiry, byte-count cap, finalize checks size/path/status, owner path | Signed URL exposure before expiry allows upload to that object |
| Firestore write amplification | Malicious authenticated user | Cost exhaustion, listener churn | Medium | Rules schemas, entitlement gates, rate limits in selected callables | Need quota/rate-limit coverage review across all callables |
| Push fanout failure | APNs/FCM outage or invalid tokens | Missed notifications/calls | Medium | Retry/lifecycle handling, invalid token marking, stuck event sweeper | Push remains best-effort |
| Local agent/runtime hang | Agent process stalls or floods stdout | User workflow blocked, battery/CPU impact | Medium | Process registry, parser/quota conditions in runner | Local runtime availability is outside cloud guarantees |

### Elevation of Privilege

| Threat | Preconditions | Impact | Likelihood | Existing mitigations | Residual risk |
|---|---|---|---:|---|---|
| Escalate from normal user session to trusted device actions | Attacker has Auth/App Check but not trusted-device private key | Approve missions, grants, device trust, Iroh keys | High impact, medium likelihood | High-risk nonce, action proof, escrow fingerprint, Signal identity binding, trusted native approver | Stolen unlocked trusted device or malware can satisfy local proof path |
| Abuse broad agent capabilities | User grants or attacker obtains grant with `shell`, `shell_unrestricted`, or `desktop_system_input` | Local command execution and data exfiltration | High | Presets, local auth proof for risky queued grants, signed authorities, anti-replay counters | No hard sandbox visible; human approval can be socially engineered |
| Disable App Check/high-risk nonce in deployment | Operator misconfiguration or compromised config | Weakened server-side trust boundary | High | Production-looking config defaults fail closed or warn; App Check enforcement default true | Requires production config readback, not code review only |
| Abuse Admin SDK/IAM/KMS | Rogue admin or compromised service account | Read/write metadata, decrypt hosted secrets, weaken rules | High | IAM/KMS separation and audit should exist | Must be audited externally; rules do not protect against Admin SDK |
| Exploit privileged daemon boundary | Local attacker can pass signed-app checks or compromise signed binary | HID/system/credential control | High | Code-signing and hardened runtime checks; HPKE credential envelope | Signed app compromise is catastrophic for this boundary |

## 8. Security Controls

### Authentication and App Check

- `assertAuth`, `assertAppCheck`, `assertOwnership`, and `enforceAuthAndAppCheck` gate standard callables (`functions/src/auth.ts:22-72`).
- App Check enforcement defaults on, and production-looking projects refuse to start if App Check is disabled (`functions/src/config.ts:68-84`).
- High-risk Computer Use flows require App Check attestation-bound custom claims, a fresh high-risk nonce, and trusted-device proof (`functions/src/appCheckAttestation.ts:98-253`, `functions/src/callables/computerUseSecurity.ts:793-860`).

Audit note: deployed config must be read back. The code has strong defaults, but an external review should not accept defaults as proof of production state.

### Gateway Sealing and PoP Authentication

- Gateway tokens are bearer-compatible only as an index hint. Every HTTP request must also prove possession of a client signing key pinned at pairing (`functions/src/hermesGateway.ts:41-48`).
- Gateway relay envelopes are designed so the phone seals to the agent key and the agent seals replies to the phone key; the server validates envelope shape but does not decrypt current sealed bodies (`functions/src/hermesGateway.ts:83-123`).
- New Gateway writes require relay v2/v3 or ratchet envelopes; v1 is legacy/read-tolerant only, and plaintext writes are closed (`functions/src/hermesGateway.ts:157-189`, `794-817`, `functions/src/callables/hermesGateway.ts:404-455`).
- Gateway send/finalize paths require bearer+PoP and reject new plaintext message bodies and plaintext attachment filenames (`functions/src/callables/hermesGateway.ts:1116-1193`, `1409-1605`).

Audit note: Signal v4 Gateway support is not a production claim unless the deployed production Signal version set is enabled and tested.

### Relay Crypto and Replay Resistance

- Relay crypto AAD binds user, connection, request, operation, sender device, peer node, counter, and key ID (`HermesRelayCrypto.swift:150-204`).
- v2 combines ephemeral-recipient and static-sender-recipient ECDH; v3 uses HPKE Auth mode. Recipient opening binds the sender public key to a pinned key rather than trusting the wire field (`HermesRelayCrypto.swift:333-435`, `464-588`).
- Authenticated request opening requires v3 HPKE Auth, pinned sender key resolution, verified Signal identity, and replay-cache freshness (`HermesRelayAuthenticatedRequest.swift:91-260`).

Audit note: The implementation itself documents limited PFS, no static-leg PFS, and no KCI protection for this relay scheme (`HermesRelayCrypto.swift:5-26`).

### CloudVault At-Rest Encryption

- CloudVault AAD includes uid, collection, document ID, field, schema version, and purpose (`CloudVaultCrypto.swift:31-62`).
- Current text/blob/payload sealing uses AES-GCM with AAD and a vault-key-derived vault key ID. Current blob schema stores `plaintextHMAC`, while legacy schema 1 may contain `plaintextSHA256` (`CloudVaultCrypto.swift:412-622`).
- Vault keys are stored in local Keychain on Apple platforms with `WhenUnlockedThisDeviceOnly`; Android uses Android Keystore-backed local encryption for key storage (`CloudVaultCrypto.swift:1374-1428`, `Android CloudVaultCrypto.kt:817-992`).
- Firestore rules reject common plaintext fields for current conversations, mobile assistant chats, CLI sessions, and mission requests (`firestore.rules:1167-1568`).

Audit note: metadata and search/index fields are intentionally not hidden, and legacy document cleanup requires production proof.

### Trusted Device and Grant Controls

- Escrow devices cannot self-mark trusted through direct Firestore writes. Trust and key roots are server-owned or callable-mediated (`firestore.rules:3314-3578`, `2686-2739`).
- Trusted-device action proof binds uid, device ID, action kind, subject ID, approve flag, and nonce; it checks escrow device trust, platform, Signal identity, key version, and signature (`computerUseSecurity.ts:793-860`).
- Device trust approval enforces high-risk nonce, target/approver identities, escrow fingerprint, and trust-chain signatures (`computerUseSecurity.ts:1177-1454`).
- Risky agent grants require capability presets, trusted source devices, local auth proof for risky queued grants, signed authority hashes, counters, and proof-consumption checks (`computerUseSecurity.ts:1964-2263`).

Audit note: this is a strong code path, but it rests on endpoint key security and correct production enforcement.

### Provider Secret Storage

- Hosted/cloud-refreshable credentials are normalized and validated through backend provider adapters, then stored as Secret Manager envelopes encrypted with a KMS-wrapped DEK (`providerAccounts.ts:168-249`, `secrets.ts:1-263`).
- Firestore stores secret resource/version references and provider metadata, not raw credentials (`shared.ts:1465-1607`).

Audit note: backend decryptability is intentional. This control protects against direct Firestore compromise, not against IAM/KMS compromise or malicious backend code.

### Push Payload Minimization

- Agent reply notifications use a generic preview when content is sealed and do not include reply text (`agentNotifications.ts:21-327`).
- VoIP/call push includes call and caller metadata (`callables/voipPush.ts:14-113`, `voipPush.ts:42-104`).

Audit note: "pushes contain no sensitive data" is too broad. The defensible claim is narrower: sealed agent reply push bodies avoid message text.

### Local Privileged Socket Boundary

- The privileged daemon validates same console UID, first-party Team ID, exact bundle IDs, designated requirements, hardened runtime, and library validation before accepting a peer (`PrivilegedPeerAuthenticator.swift:14-84`, `PrivilegedSocketTrust.swift:15-204`).
- Remote Unlock credential envelopes use HPKE with context-bound info/AAD (`RemoteUnlockCredentialEnvelopeCrypto.swift:5-122`).

Audit note: this is a local trust boundary. A signed app compromise or local privilege escalation changes the risk model.

## 9. Security Properties

| Property | Actual mechanism | Confidence | Gaps and caveats |
|---|---|---:|---|
| Confidentiality of current Hermes Gateway message bodies | New writes require relay/ratchet sealed envelopes; server validates shape and stores ciphertext | High for reviewed code paths | Endpoint plaintext, metadata leakage, deployed config/rules, and legacy data remain out of claim |
| Attachment confidentiality | Sealed bytes before upload; sealed manifest for filename/content type/byte count; finalize validates storage object and ciphertext hash | High for current Gateway attachment path | Size/path/status/ciphertext hash visible; signed upload URL risk until expiry |
| CloudVault at-rest content confidentiality | AES-GCM payload/blob/text envelopes with path-bound AAD and local vault keys | Medium/high | Metadata, hashes, facets visible; legacy schema/backfill state needs proof; endpoint compromise defeats it |
| Provider credential confidentiality | Secret Manager envelopes with KMS-wrapped DEKs; Firestore only stores refs | Medium | Backend/IAM/KMS can decrypt; not E2EE/zero-knowledge |
| Authenticity of Gateway requests | Bearer token hash plus PoP signature pinned at pairing; active client/scope checks | High for current code | Token+PoP private key compromise impersonates client |
| Authenticity of trusted-device actions | Auth/App Check/high-risk nonce plus trusted-device signed proof and Signal identity binding | High for current code | Stolen unlocked trusted device or malware can produce valid user-context actions |
| Integrity of sealed payloads | AES-GCM/HPKE auth tags and AAD binding; Firestore/Storage create-if-absent and validation | High for ciphertext tamper detection | Malicious endpoint can create valid malicious plaintext/ciphertext |
| Replay resistance | Relay authenticated request replay cache, counters, request IDs; high-risk nonces; agent grant counters/proof consumption | Medium/high for covered flows | Not universal across every API; cache storage and distributed behavior should be tested |
| Forward secrecy | Relay v2/v3 include ephemeral leg; ratchet implementation has chain/ratchet keys and skipped-key limits | Limited | Relay crypto explicitly lacks static-leg PFS and KCI protection; endpoint key compromise remains high impact |
| Endpoint trust | Plaintext intentionally exists on endpoint before seal/after open | Explicit assumption, not a guarantee | No crypto can protect against fully compromised endpoint |
| Metadata privacy | Some content fields sealed; push previews minimized; project memory IDs opaque | Low/medium | Significant metadata remains visible by design |
| Availability | Rate limits, TTLs, retries, size caps, sweeper patterns, process management | Medium | Firebase/APNs/FCM/provider/local runtime outages remain best-effort |
| Admin blindness | Sealed content bodies can remain confidential from cloud/admin without endpoint keys | Narrow | Admins can see metadata, decrypt hosted provider secrets with IAM/KMS, delete/corrupt data, deploy bad code/rules |

## 10. Security Claims Review

### Claims We Can Defend

1. Current Hermes Gateway message, event, and attachment write paths require sealed envelopes and reject new plaintext bodies/filenames.
2. Hermes Gateway bearer tokens alone are insufficient for active HTTP access because requests must also prove possession of the pairing-pinned client signing key.
3. Current CloudVault-backed content mirrors use client-side AES-GCM envelopes with AAD, and Firestore rules reject common plaintext content fields on current write paths.
4. Iroh pairing records are signed and freshness-limited, and publication is routed through server-owned/high-risk trusted-device paths.
5. Trusted-device promotion and high-risk Computer Use actions are guarded by App Check attestation binding, high-risk nonces, escrow fingerprint checks, Signal identity binding, and signed action proofs.
6. Hosted provider credentials are kept out of Firestore plaintext and are stored in Secret Manager using KMS-backed envelope encryption.
7. Agent reply push notifications use a generic preview rather than message text when content is sealed.
8. Encrypted session backups and search results store sealed bodies/previews/snippets, while search operates over keyed hashes and plaintext facets.

### Claims We Cannot Defend

1. "BurnBar cannot see anything." BurnBar sees metadata, routing state, search hashes/facets, usage and billing data, push/call metadata, entitlements, provider account metadata, and hosted provider secret refs.
2. "All BurnBar communications are end-to-end encrypted." Some subflows are sealed; others are metadata/control-plane flows, provider credential flows, or local process flows.
3. "BurnBar uses Signal for all messages." Signal at-rest/Gateway v4 support exists, but production Gateway Signal writes are disabled unless explicitly enabled.
4. "BurnBar provides full forward secrecy." The relay crypto documents limited forward secrecy and explicit caveats.
5. "BurnBar protects against compromised endpoints." Endpoints and local agent runtimes see plaintext and hold keys.
6. "Rogue admins cannot affect users." Admin/IAM/KMS access can expose metadata, decrypt hosted provider credentials, delete/corrupt data, or deploy modified code/rules.
7. "All historical data is already scrubbed." The repo contains legacy-compatible paths and comments; production backfill evidence is required.
8. "Push notifications contain no sensitive metadata." Agent replies use generic preview, but call/VoIP pushes include call IDs, connection IDs, paired device IDs, and display/caller names.
9. "Local agents are sandboxed." The reviewed process runners launch local executables with user-level process privileges; no hard sandbox is evident from those files.
10. "Hosted provider credentials are zero-knowledge." Hosted/cloud-refreshable provider credentials are intentionally decryptable by backend infrastructure with the right IAM/KMS access.
11. "Hosted MCP can search decrypted CloudVault content in the cloud by default." The hosted path cannot derive vault trapdoors without the local decrypt shim unless an explicit remote-readable mode is separately enabled and audited.

## 11. Residual Risks

1. Endpoint compromise is the top residual risk. A compromised phone, Mac, Android device, or local runtime can read plaintext and use local keys before cryptography helps.
2. Local agent runtime privilege is high. Agents can be granted powerful local capabilities, including shell and desktop input categories, and no reviewed process sandbox provides a hard containment boundary.
3. Metadata privacy is limited. Even where content is sealed, the cloud stores routing, timing, size, status, device, provider/model, billing, token/cost, hash, and access-pattern metadata.
4. Hosted provider credentials depend on IAM/KMS. This is a backend secret management problem, not an E2EE property.
5. Deployment drift can break security claims. App Check, high-risk nonce settings, Firestore/Storage rules, Functions code, Remote Config, and Gateway Signal flags must be verified in production.
6. Legacy plaintext and legacy hash fields need production proof. Current code rejects many new plaintext writes, but the auditor should run backfill and data-shape scans.
7. Push and provider ecosystems are third-party trust boundaries. APNs/FCM and provider APIs can see metadata and affect availability.
8. Admin SDK bypasses rules. Firestore rules are strong for clients but not for backend or admin credentials.
9. Realtime relay/fallback status is ambiguous from static review alone. Any deployed WSS/Hermes realtime fallback should be explicitly scoped and tested.
10. Logging safety is pattern-based. The scrubber reduces obvious secret leakage but does not prove arbitrary new error fields or strings are safe.

## 12. Open Questions for Cure53 Intake

1. What exact production commit, Functions artifact, Firestore ruleset, Storage ruleset, Remote Config, and environment variables are deployed?
2. Is App Check enforced for Functions, Firestore, and Storage in production, and is high-risk nonce enforcement enabled with no breakglass override?
3. Is Hermes Gateway Signal v4 production write support enabled or disabled in the deployed environment?
4. Is `services/hermes-realtime-relay` deployed, and under what conditions do clients fall back from Iroh/direct transport to WSS/realtime relay?
5. What production data scan proves no current plaintext Gateway message text, attachment filenames, project names, session bodies, or legacy plaintext fields remain outside accepted migration windows?
6. Which service accounts can decrypt provider credentials through Secret Manager/KMS, deploy Functions, or write Firestore with Admin SDK?
7. Are KMS decrypt operations, Secret Manager accesses, admin writes, and high-risk callables centrally audited with alerting?
8. What local authentication policy is required before a trusted device approves Computer Use missions, risky grants, or trust promotion?
9. Are local agent runtimes sandboxed in any build configuration not visible in the reviewed process runners?
10. What is the production push payload inventory for APNs/FCM across agent replies, VoIP calls, Mercury media, and Android data pushes?
11. What is the mobile and desktop key backup/recovery/deletion story when a user loses all trusted devices?
12. What are the intended user-visible security claims for launch copy, website copy, app store listings, and enterprise/commercial docs?

## 13. Recommended Next Steps

### Before External Audit

1. Pin the audit commit and export deployed artifact hashes for Functions, rules, Storage rules, mobile builds, macOS builds, and Android builds.
2. Produce production readbacks for App Check enforcement, `enforceAppCheck`, high-risk nonce enforcement, Hermes Gateway Signal flags, and Gateway plaintext grace state.
3. Run a production-safe data-shape scan for legacy plaintext fields, legacy `plaintextSHA256`, plaintext Gateway text, plaintext attachment filenames, plaintext project/session names, and hosted-MCP legacy `projectName` fields.
4. Export IAM/KMS/Secret Manager policy and audit-log samples showing which principals can decrypt hosted provider credentials.
5. Create auditor seed accounts with paired iOS, Android, and macOS devices; one trusted device; one pending device; one Hermes Gateway pairing; one Iroh pairing; one hosted provider credential test account; one encrypted session/search corpus; and one Computer Use approval flow.
6. Prepare crypto test vectors for CloudVault, Hermes relay v2/v3, ratchet, Signal at-rest envelopes, Iroh pairing signatures, Remote Unlock HPKE envelopes, and trusted-device action proofs.
7. Document every place endpoint plaintext may be cached locally, including app logs, local databases, stdout/stderr buffers, crash reports, Sentry breadcrumbs, and provider/runtime logs.

### Engineering Hardening

1. Add CI tests that assert Gateway plaintext write rejection for message, event, and attachment paths.
2. Add Firestore rules tests for every claimed plaintext-forbidden field and trust-root server-owned collection.
3. Add a repo scanner and production-safe admin scanner for plaintext field names and legacy envelope schemas.
4. Add a release gate that fails if production-looking config disables App Check or high-risk nonce enforcement.
5. Add an auditor-facing IAM/KMS least-privilege review and alerting runbook for Secret Manager decrypts.
6. Decide whether local agent runtimes require a hard sandbox, separate user, entitlements, filesystem broker, or explicit "runs as your user" product disclosure.
7. Minimize VoIP/call push payloads and document exactly which fields APNs/FCM receive.
8. Decide whether profile photos should remain authenticated-public or move to owner/relationship-scoped access.
9. Close or formally document WSS/realtime fallback behavior, including whether frames are always sealed and what metadata the relay sees.
10. Convert defensible security claims into claim tests so marketing and docs cannot drift ahead of implementation.

## 14. Evidence Map

### Authentication, App Check, and Logging

- `functions/src/auth.ts:22-72` - Auth, App Check, ownership helpers.
- `functions/src/config.ts:68-106` - App Check and high-risk nonce defaults.
- `functions/src/appCheckAttestation.ts:98-253` - App Check claim binding and high-risk nonce flow.
- `functions/src/logging.ts:1-195` - Structured logging scrubber and Sentry capture wrapper.

### Firestore and Storage Rules

- `firestore.rules:1167-1227` - `conversations` owner access, sealed payload requirement, plaintext field rejection.
- `firestore.rules:1241-1328` - `mobile_assistant_chats` and `cli_sessions` sealed schemas.
- `firestore.rules:1330-1568` - mission requests, sealed fields, server/callable-only approval resolution.
- `firestore.rules:2105-2198` - account recovery, cloud vault state, key wrappers.
- `firestore.rules:2470-2602` - Hermes Gateway clients/destinations/events/messages/attachments and Iroh pairing roots.
- `firestore.rules:2608-2739` - Iroh audit, media events, phone-control verifier keys, relay sender keys, grant authorities.
- `firestore.rules:3314-3675` - escrow devices, escrow public keys, Signal identity keys, Signal directory private-state rejection.
- `storage.rules:5-28` - session log object rules, profile photo access, default deny.

### Hermes Gateway and Crypto

- `functions/src/hermesGateway.ts:41-189` - Gateway token/PoP model, relay envelope model, Signal staging, plaintext cutoff.
- `functions/src/hermesGateway.ts:691-817` - Signal production gating and relay envelope validation.
- `functions/src/callables/hermesGateway.ts:404-455` - body resolution and plaintext rejection.
- `functions/src/callables/hermesGateway.ts:810-865` - bearer+PoP request resolution.
- `functions/src/callables/hermesGateway.ts:884-982` - device start and pending pairing session.
- `functions/src/callables/hermesGateway.ts:1116-1193` - message send sealed-write path.
- `functions/src/callables/hermesGateway.ts:1409-1605` - attachment init/finalize sealed upload path.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift:5-588` - relay security considerations, AAD, v2/v3 crypto.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift:130-399` - ratchet encrypt/decrypt, skipped-key handling, AAD validation.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:91-260` - replay cache and authenticated relay opening.
- `AgentLens/Services/HermesRelaySenderTrustResolver.swift:22-163` - pinned relay sender key and verified Signal identity resolver.

### CloudVault, Signal, Search, and Memory

- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:31-622` - AAD, vault key ID, AES-GCM seal/open, blob HMAC.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:1374-1428` - Apple Keychain vault key store.
- `AgentLens/Services/CloudVaultKeyAccess.swift:172-358` - macOS vault key load/unwrap/create/wrap flow.
- `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift:170-388` - iOS vault key load/unwrap/create/wrap flow.
- `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt:39-409` - Android CloudVault AAD and envelope compatibility.
- `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt:817-992` - Android device keypair and local secret box.
- `OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift:62-268` - Signal at-rest payload seal/open and sender authentication.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SignalEnvelopeAAD.swift:3-128` - Signal envelope canonical AAD binding.
- `functions/src/callables/encryptedSearch.ts:52-907` - encrypted session blob upload/download, search index, project memory, search/query APIs.
- `functions/src/callables/conversationQuery.ts:132-163` - plaintext facets and sealed row projection.

### Provider Secrets, Push, MCP, Agents, and Daemon

- `functions/src/callables/providerAccounts.ts:43-249` - provider account connect and hosted credential storage entrypoints.
- `functions/src/secrets.ts:1-263` - Secret Manager and KMS envelope encryption helpers.
- `functions/src/callables/shared.ts:1465-1607` - provider secret ref writes and provider adapter connection flow.
- `functions/src/agentNotifications.ts:21-327` - generic agent reply notification payloads.
- `functions/src/callables/voipPush.ts:14-113` and `functions/src/voipPush.ts:42-104` - call/VoIP push metadata.
- `functions/src/callables/remoteMcp.ts:18-128` - remote MCP grants and encrypted-search-required behavior.
- `functions/src/remoteMcpOAuth.ts:23-100` and `functions/src/remoteMcpGrant.ts:38-110` - HMAC tokens, refresh token hashing, grant expiry.
- `services/hosted-mcp/src/auth.ts:83-152` and `services/hosted-mcp/src/server.ts:77-155` - hosted MCP bearer token and origin/protocol validation.
- `tools/openburnbar-mcp-remote/src/vaultStore.ts:32-68` - local decrypt shim vault-key storage and insecure fallback opt-in.
- `AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift:8-250` - local CLI runtime process execution.
- `AgentLens/Services/ManagedAgentRuntime/ManagedRuntimeProcessRunner.swift:22-66` - managed runtime execution.
- `OpenBurnBarDaemon/Sources/OpenBurnBarRemoteAccessAgentCore/PrivilegedPeerAuthenticator.swift:14-84` - daemon peer validation.
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift:15-204` - privileged socket signing identity and runtime flag validation.
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/RemoteUnlockCredentialEnvelopeCrypto.swift:5-122` - Remote Unlock HPKE credential envelope.
