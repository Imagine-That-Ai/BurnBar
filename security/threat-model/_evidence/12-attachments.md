# Evidence — Attachments / Media / Storage (domain: attachments-storage)

Reviewer: senior product-security. Source of truth = CURRENT code. Commit `c813a0d2f`.
Two distinct attachment subsystems exist and must not be conflated:

- **Hosted-gateway attachments** (HTTP, Cloud Functions + GCS signed URLs):
  `functions/src/callables/hermesGateway.ts` `handleAttachmentInit` / `handleAttachmentFinalize` /
  `handleHermesGatewayAttachmentDownloadUrl`. Object lives in GCS at
  `users/{uid}/hermes_gateway_attachments/{clientId}/{attachmentId}`.
- **Mercury peer-to-peer media** (iroh content-addressed blobs, NOT GCS):
  `OpenBurnBarCore/.../OpenBurnBarMedia/MediaFileTransferService.swift`,
  `AgentLens/Services/Media/MacFileTransferService.swift`,
  `OpenBurnBarMobile/Services/Media/iOSFileTransferService.swift`,
  `crates/openburnbar-iroh/src/blobs.rs`.
- **Encrypted-search session blobs** (adjacent signed-URL surface):
  `functions/src/callables/encryptedSearch.ts` + `functions/src/callables/shared.ts assertUserStoragePath`.

## Components & files reviewed
- functions/src/callables/hermesGateway.ts (init 1409-1511, finalize 1513-1605, downloadUrl 1607-1666, helpers 196-540)
- functions/src/hermesGateway.ts (constants 41/51, gatewayPlaintextWriteAllowed 188-190)
- storage.rules (whole, 1-31)
- functions/src/callables/encryptedSearch.ts (upload 78-101, download 117-141)
- functions/src/callables/shared.ts (assertUserStoragePath 514-534)
- OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFileTransferService.swift (publish 101-130, fetch 135-152, inboxURL 162-169, inferMime 179-194)
- AgentLens/Services/Media/MacFileTransferService.swift (receive 376-442, sealAtRest 516-543, quarantine 555-576)
- AgentLens/Services/Media/MediaFileTransferServiceFactory.swift (inbox dir 20-34)
- OpenBurnBarMobile/Services/Media/iOSFileTransferService.swift (handleAdvertise 135-208)
- crates/openburnbar-iroh/src/blobs.rs (publish_blob 188-221, fetch_blob 228-294)
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift (manifest 1712-1738)
- OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift (sealed at-rest manifest)
- website/src/data/trust.generated.ts (public claims)

## Controls present (control — file:line symbol — strength — note)
- Direct Storage SDK access denied by default; only session_logs + avatars match — storage.rules:26-28 catch-all `allow read,write: if false` — strong — gateway attachment objects have NO match block, so all gateway upload/download is via signed URLs only.
- session_logs write capped 10MB + forced octet-stream — storage.rules:10-14 — strong.
- Sealed-only writes for new gateway attachments — hermesGateway.ts:1439-1444 + hermesGateway.ts:188-190 `gatewayPlaintextWriteAllowed` always false — strong — agent seals bytes + {fileName,byteCount,contentType} into relay/ratchet/signal envelope before upload; server stores opaque octet-stream.
- Sealed object path carries NO fileName segment — hermesGateway.ts:1470-1472 storagePath — strong — filename never appears in a server/Storage-listing-visible path.
- Plaintext filename rejected for new writes; only legacy fallback, slash-stripped — hermesGateway.ts:1445-1452 — moderate.
- Content-type denylist (html/js/xml/svg) on legacy path — hermesGateway.ts:200-215 `assertSafeAttachmentContentType` — moderate — sealed path forces application/octet-stream (1455-1457) so denylist mostly moot for new uploads.
- Upload signed URL scoped to exact object + fixed contentType, 10-min expiry — hermesGateway.ts:1473-1479 getSignedUrl v4 write — strong.
- Init is create-if-absent in a transaction (409 on re-init) — hermesGateway.ts:1502-1509 — strong — prevents re-minting an upload URL over an existing manifest.
- byteCount bounds 1..50MB at init — hermesGateway.ts:1461-1464; HERMES_GATEWAY_MAX_ATTACHMENT_BYTES = 50*1024*1024 hermesGateway.ts:51 — moderate.
- Finalize: client-ownership (clientId), destination, status, expiry, storage-path-prefix confinement — hermesGateway.ts:1524-1555 — strong.
- Finalize: observed object size must EQUAL declared byteCount, else status=rejected — hermesGateway.ts:1567-1573 — strong — defeats lie-about-size on the GCS path.
- Finalize: server recomputes sha256 of stored bytes; rejects on expected-hash mismatch — hermesGateway.ts:1582-1586 `sha256ForStorageFile` 492-505 — strong (ciphertext integrity gate).
- Download URL: auth + App Check + status=='uploaded' + clientId/destination match + path-prefix confinement + 10-min read URL — hermesGateway.ts:1614-1658 — strong.
- Mercury blobs are content-addressed; iroh export verifies BLAKE3 hash of the ticket — crates/openburnbar-iroh/src/blobs.rs:276-282 `store.blobs().export(ticket.hash(), ...)` — strong (bytes cannot be substituted for the committed hash).
- Mercury on-disk inbox name = blobHash (hashed) + extension-only from sender filename — MediaFileTransferService.swift:162-169 `inboxURL` — strong (no path traversal via filename; uses `pathExtension`, blobHash slashes replaced).
- Mac receive: capability-gate admission (entitlement + daily byte cap + kill switch + concurrency) BEFORE fetch — MacFileTransferService.swift:391-407 — moderate (charges advertised size, see gaps).
- Mac receive: seal-at-rest under media session key (AES-256-GCM OBMFA1, AAD-bound to manifestId+blobHash), atomic replace — MacFileTransferService.swift:420-543 `sealReceivedFileAtRest` — strong WHEN a session key exists.
- Mac receive: com.apple.quarantine xattr applied to inbound file — MacFileTransferService.swift:423,555-576 `applyInboundQuarantine` — moderate.
- Firestore at-rest media manifest seals filename via CloudVault, stores only opaque fields — MediaAttachmentManifestStore.swift (sealedFilename / encrypted dict) — strong.
- encryptedSearch upload forces octet-stream + size cap — encryptedSearch.ts:81-92 — strong.
- encryptedSearch download path strictly confined to users/{uid}/session_logs/.../bodies/*.json.aesgcm — shared.ts:514-534 `assertUserStoragePath` + existence check before signing — strong.

## Claims verified against code (claim — verdict — evidence — note)
- "Server never sees plaintext filename/bytes for gateway attachments" — Defensible — hermesGateway.ts:1414-1418,1445-1457,1470-1472 — sealed path stores octet-stream at fileName-free path; filename sealed in envelope.
- "Signed URLs are short-lived (10-15 min)" — Defensible — init 1473, finalize-implicit, download 1653, encryptedSearch 88/135 all = 10*60*1000 (10 min).
- "Finalize verifies size + hash + path + status" — Defensible — hermesGateway.ts:1538-1586.
- "Legacy plaintext is read-only, not a write path" — Defensible — hermesGateway.ts:188-190 returns false unconditionally; init 1439 + finalize 1578 gate on `sealed`.
- "Media manifest records only opaque hash/mime/size/peer-id-hash; filename sealed on-device, never readable by server" (trust.generated.ts) — Partial — TRUE for the Firestore at-rest store (MediaAttachmentManifestStore sealedFilename) but the WIRE manifest `HermesRealtimeRelayAttachmentManifest` (Types 1712-1738) carries PLAINTEXT `filename`,`mime`,`size` and is placed in the advertise frame (MacFileTransferService.swift:211-218). Server-readability then depends on relay-frame E2EE (out-of-domain). See Overclaims.
- "Received file is not plaintext at rest in Caches" (RR-18 intent, comment 414-419) — Partial — TRUE on Mac only WHEN frameSealKeyProvider returns a key (421); no key ⇒ plaintext retained (quarantine-only). iOS receive path applies NEITHER seal NOR quarantine (handleAdvertise 155-181). UNKNOWN whether a session key is always present.
- "Attachment bytes integrity-checked" — Defensible — GCS path sha256 (1582), Mercury path BLAKE3 content-address (blobs.rs:276-282).

## Threats (T-ATT-NN)
- T-ATT-01 — Decompression/oversize resource exhaustion via lied-about Mercury manifest.size — Tampering/DoS (STRIDE T+D; Agentic resource-exhaustion) — Sev High — component MediaFileTransferService.fetch + capability gate — path: malicious peer advertises size=1KB (passes daily byte cap, MacFileTransferService.swift:391-395 charges `manifest.size`) but the BlobTicket commits to a 10GB blob; fetch_blob (blobs.rs:258-282) downloads the FULL committed blob to Caches with NO size cap and NO comparison of actual `bytes_total` (284) vs `manifest.size` — existing mitigation: capability gate on advertised size only — gap: no streaming byte ceiling on iroh download; no post-fetch size==manifest.size reject; gateway-path size-equality check (1570) has NO equivalent here — residual risk: disk-fill / quota exhaustion on receiver before any reject. CWE-409/CWE-770/CWE-400.
- T-ATT-02 — iOS received media stored plaintext at rest (no seal, no quarantine, no gate) — Info-disclosure (STRIDE I) — Sev Medium — component iOSFileTransferService.handleAdvertise — path: handleAdvertise (135-208) calls service.fetch then only records the URL; lacks the Mac path's capabilityGate (391), sealReceivedFileAtRest (421) and applyInboundQuarantine (423); inbox = Caches/Mercury/Inbox (factory analog). No FileProtectionType set (rg found none) — existing mitigation: iOS sandbox + default Data Protection (Class C until first unlock) — gap: platform parity; no explicit complete protection; no byte budget — residual risk: plaintext media recoverable from an unlocked/jailbroken device backup; unbounded inbound. CWE-312/CWE-770.
- T-ATT-03 — Wire-manifest filename/mime/size leak metadata to relay if frame not E2EE-sealed — Info-disclosure / LINDDUN Disclosure — Sev Medium — component HermesRealtimeRelayAttachmentManifest in advertise frame — path: plaintext `filename`,`mime`,`size` (Types 1712-1738) embedded in `frame.media.attachment` (MacFileTransferService 211-218); confidentiality depends entirely on the realtime-relay frame-sealing layer (out of this domain) — existing mitigation: at-rest Firestore manifest seals filename — gap: transport manifest unsealed at this layer; trust doc implies "never readable by server" — residual risk: filename/size metadata visible to relay if frame E2EE not active. CWE-201/CWE-359.
- T-ATT-04 — Unauthenticated Mercury manifest metadata (no MAC/sig) — Tampering (STRIDE T) — Sev Medium — component HermesRealtimeRelayAttachmentManifest — path: manifest has no signature field (Types 1712-1738); `filename`,`mime`,`size`,`peerDeviceId` all sender-controlled; only `blobHash` is self-authenticating via iroh — existing mitigation: bytes bound to blobHash on export — gap: displayed filename/mime not bound to the bytes; a peer can present misleading name/type for content of a different real type — residual risk: spoofed file identity / content-type confusion (e.g. .jpg name on an executable payload). CWE-345/CWE-646.
- T-ATT-05 — Content-type trust on display via extension-only inferMime — Spoofing (STRIDE S) — Sev Low — component MediaFileTransferService.inferMime 179-194 — path: receiver mime derived from sender-chosen extension; default octet-stream; UI may render/preview by mime — existing mitigation: quarantine xattr (Mac) gates Gatekeeper on open — gap: no server/receiver content sniffing on Mercury path; sender controls extension and mime — residual risk: type confusion in preview. CWE-434/CWE-646.
- T-ATT-06 — Seal-at-rest silently skipped when no media session key — Info-disclosure (STRIDE I) — Sev Low/Medium — component MacFileTransferService 420-422 — path: `if let sealKey = frameSealKeyProvider(...)` — when nil, the freshly-fetched PLAINTEXT blob persists in Caches inbox (quarantine-only) — existing mitigation: quarantine xattr; sandbox — gap: fail-open (no key ⇒ keep plaintext rather than refuse) — residual risk: plaintext media at rest when key negotiation absent. CWE-311.
- T-ATT-07 — Legacy content-type denylist incomplete & largely dead — Tampering — Sev Info — component assertSafeAttachmentContentType 200-215 — path: denylist (no allowlist) misses e.g. application/x-shockwave-flash, but sealed path forces octet-stream so list only applies to the disabled legacy plaintext write path — existing mitigation: sealed-only writes — gap: defense-in-depth uses denylist not allowlist — residual risk: minimal while legacy writes disabled. CWE-183/CWE-434.
- T-ATT-08 — Gateway download URL lacks forced Content-Disposition/Content-Type — Info-disclosure / XSS-adjacent — Sev Low — component handleHermesGatewayAttachmentDownloadUrl 1653-1658 — path: read signed URL issued with no responseDisposition/responseType; object is octet-stream (sealed) so low risk, but a legacy non-octet object served inline could render in a browser web client — existing mitigation: sealed objects are octet-stream — gap: no explicit `responseDisposition=attachment` — residual risk: low (sealed). CWE-79 (adjacent).

## Gaps / missing controls
- No streaming size ceiling on iroh `fetch_blob` and no post-fetch `bytes_total == manifest.size` assertion (blobs.rs:284 reads it, discards) — unlike the GCS finalize size-equality check. (T-ATT-01)
- iOS receive path omits capability gate, seal-at-rest, and quarantine present on Mac. (T-ATT-02)
- No explicit `FileProtectionType.complete` / `isExcludedFromBackup` on the Mercury inbox (rg found none in Media services). (T-ATT-02)
- Wire-manifest metadata (filename/mime/size) is neither sealed at this layer nor MAC-bound to the blob. (T-ATT-03, T-ATT-04)
- Mercury mime is extension-inferred and sender-trusted; no content sniffing. (T-ATT-05)
- Seal-at-rest is fail-open on missing session key. (T-ATT-06)

## Overclaims
- Trust copy "media manifest ... file name is sealed on-device (sealedFilename) and never readable by the server" (website/src/data/trust.generated.ts) is precise ONLY for the Firestore at-rest manifest. The TRANSPORT manifest (`HermesRealtimeRelayAttachmentManifest`, Types 1712-1738) carries a cleartext `filename` and is embedded in the advertise frame; "never readable by the server" holds only if the relay frame is E2EE-sealed at a different layer. Should be qualified.
- RR-18 comments (MacFileTransferService 414-419) assert received files are "not plaintext in the sandbox Caches inbox" — true only when a session key exists (Mac) and not at all on iOS. Stated more absolutely than the code guarantees.

## Crypto / protocol notes
- Gateway sealed attachments: agent-side AEAD (relay/ratchet/signal envelope) seals plaintext bytes; server stores opaque octet-stream and gates integrity on recomputed SHA-256 of the CIPHERTEXT (hermesGateway.ts:1582). byteCount is ciphertext length (~plaintext + 28B GCM overhead) per comment 1417. Server holds NO content key — keys are agent/device held. E2EE for content is plausible IF envelope keys are device-held (verify in crypto domain).
- Mercury at-rest seal: AES-256-GCM (MediaFrameAEAD/OBMFA1), AAD bound to manifestId(FNV-1a gopID 547-553)+blobHash; key = per-media-session key, rotates with session (so persistence past session ⇒ unreadable). Atomic temp+replace prevents truncated plaintext.
- Mercury wire integrity: BLAKE3 content-addressing via iroh; export verifies hash → byte substitution infeasible. Metadata NOT covered.

## Open questions / UNKNOWN
- Is the realtime-relay advertise FRAME E2EE-sealed at the relay layer such that the cleartext wire `filename`/`mime`/`size` never reach the server? (resolves T-ATT-03; out-of-domain — check realtime-relay/crypto domain).
- Is `frameSealKeyProvider` guaranteed non-nil for every inbound Mercury transfer in production, or can media land unsealed on Mac? (resolves T-ATT-06).
- Does iroh-blobs enforce ANY internal max-download size, or is `fetch_blob` truly unbounded? (resolves T-ATT-01 severity) — needs iroh-blobs version/config review.
- Are gateway/Mercury inbox files on iOS protected with Data Protection complete-until-first-unlock, or default? (resolves T-ATT-02) — needs deployed entitlements/Info.plist check.
- Deployed GCS bucket: lifecycle TTL on hermes_gateway_attachments objects and CORS/responseDisposition policy? (resolves T-ATT-08) — needs deployed bucket config.
