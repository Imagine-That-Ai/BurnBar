# Item 3 — Mac (AgentLens) Signal producer

## Build prerequisite
Copied Mac `AgentLens/Resources/GoogleService-Info.plist` from the main checkout; xcframeworks already symlinked. `xcodebuild -scheme OpenBurnBar -destination 'platform=macOS'` baseline = **BUILD SUCCEEDED** (env good).

## De-risked the scout's gotchas
- `CloudVaultResolvedKey` (AgentLens/Services/CloudVaultKeyAccess.swift:9) **already has** `signalIdentity` (populated by `keyForWriting` via `publishCloudVaultKey`).
- `KnowledgeSyncService` resolves Firestore via `Firestore.firestore()` **directly** (not the gateway abstraction the scout feared) and already has a working `atRestRecipients`. So the Mac producers use `Firestore.firestore()` like Pensieve.

## Added / wired
- **`AgentLens/Services/MacCloudVaultSignalPayloads.swift`** (new) — `signalSealingIsEnabled` (sealingScheme gate) + `signalEnvelopeIfEnabled` (seal to local + trusted devices) + `openSignalPayloadIfPresent` (Signal-first open + relocation guard) + `atRestRecipients` (fail-closed on missing/invalid peer identity, excludes local). Mac-typed mirror of iOS `MobileCloudVaultSignalPayloads`.
- **`ChatThreadSyncService.swift`** dual-write — after the legacy AES-GCM `sealedPayload`, adds `signalEnvelope` (collection `chat_threads`, docId `{deviceId}_{thread.id}`, field `signalEnvelope`) sealed from the SAME `payloadData`. Gated → inert in production until the flip.
- `xcodegen generate` re-included the new file (project.yml `path: AgentLens` glob).

## Verification
`xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' -derivedDataPath /tmp/obb-mac-dd CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED** with the producer changes (full macOS app compiles).

## Conversations producer + read + keyForReading — COMPLETED (2026-06-05)
- `ConversationCloudSealer.encodePlaintext(_:)` exposes the exact bytes `seal` encrypts, so `ConversationSyncService.sync()` dual-writes `signalEnvelope` (collection `conversations`, docId `{deviceId}_{record.id}`) sealed from the SAME plaintext.
- `ConversationCloudSealer.open(...)` is now Signal-first (optional uid/docId/signalIdentity; legacy AES-GCM fallback), wired at `DownloadSyncService:449` (passes uid + `doc.documentID` + `vaultKey?.signalIdentity`).
- `MacCloudVaultKeyAccess.keyForReading` now populates `signalIdentity` (via `OpenBurnBarSignalIdentityKeyStore().load`, never creates) on both return paths — so Mac read paths can open Signal envelopes.
- Verified: macOS `xcodebuild` **BUILD SUCCEEDED** (3rd build) with all of the above.

## Remaining (honest)
- `chat_threads` is a write-only Mac service (no Mac read path to wire); its `openSignalPayloadIfPresent` is available if a read path is later added.
- session_logs domain stays legacy (sealingScheme nil; lower priority, inert).
- All inert in production (gate fail-closed). On-device Apple proof [blocked] (iPhone/iPad offline to Xcode); Android on-device proof run on the Galaxy.
