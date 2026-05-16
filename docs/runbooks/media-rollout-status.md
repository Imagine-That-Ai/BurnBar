# Mercury Media Rollout Status

Operator log mirroring `docs/runbooks/iroh-rollout-status.md`. Each entry records gate status, what landed, what is blocked or pending, and the next action. New entries are appended at the bottom in reverse chronology so the latest state is always immediately visible from the table of contents at the top of the file.

The plan of record is `plans/2026-05-15-mercury-media-master-plan.md`. The seven phases below correspond directly to phases 1-7 in that plan.

| Phase | Theme | Flag | Gate status |
|---|---|---|---|
| 1a | iroh-blobs file send/receive substrate | `media_blob_transfer_enabled` | Substrate landed 2026-05-15 |
| 1b | File transfer end-to-end (IrohBlobNode + Mac/iOS file services) | `media_blob_transfer_enabled` | Source-complete 2026-05-15; needs TestFlight verify |
| 2 | File send UI + `hosted_media_sync` SKU + Cloud Functions | `media_blob_transfer_ui_enabled` | Source-complete 2026-05-15 |
| 3 | Mac → iOS one-way screen share | `media_screen_share_enabled` | Source-complete 2026-05-15 |
| 4 | Mac ⇄ iOS audio | `media_audio_enabled` | Source-complete 2026-05-15 |
| 5 | Mac ⇄ iOS video + CallKit + budget | `media_video_enabled` | Source-complete 2026-05-15 |
| 6 | iPad multicam + PiP | `media_ipad_multicam_enabled` | Source-complete 2026-05-15 |
| 7 | macOS PiP + WSS retirement | `media_macos_pip_enabled` | Source-complete 2026-05-15 |

---

## 2026-05-15 — Phase 1 scaffolding landed

**Gate status:** in progress; xcframework rebuild + manual TestFlight verification remain.

Completed:
- Pure-Swift substrate published as a new SwiftPM target `OpenBurnBarMedia` in `OpenBurnBarCore/Package.swift`, conditionally linked alongside the existing `OpenBurnBarIrohRelay` package. Target is buildable from a fresh checkout regardless of whether `Vendor/OpenBurnBarIroh.xcframework` is present.
- Substrate source files: `MediaStreamClass.swift` (canonical class identifiers shared with the Rust crate), `MediaPacketCodec.swift` (length-prefix codec parallel to `IrohRelayFrameCodec` for binary media frames), `MediaFrame.swift` (typed envelope), `BitrateController.swift` (GCC-lite encoder ceiling), `MediaSessionMetadata.swift`, `MediaCapabilityGate.swift` (protocol surface — Mac and iOS provide implementations in later phases), `MediaBudgetEnvelope.swift` (active envelope from `ops/media_budget_status/current`).
- `HermesRealtimeRelayFrame` extended with `media: HermesRealtimeRelayMediaPayload?` and three new frame types (`media.classify`, `media.blob.advertise`, `media.blob.ack`). Forward-compat verified — older decoders ignore the new field, newer decoders accept its absence.
- Mac + iOS dispatch: `IrohRelayRequestHandler` (Mac) and `HermesIrohRelayTransport` (iOS) handle the new media frame types via stub handlers gated on `media_blob_transfer_enabled` (default off). Phase 1 stubs log + count; the full publish/fetch path activates after the xcframework reships.
- Rust scaffolding (Phase 1a — substrate): `crates/openburnbar-iroh/src/blobs.rs` module imports `iroh-blobs = "0.92"` (the line that targets `iroh ^0.91`) and publishes `BlobTicketBytes`, `BlobTransferStats`, `parse_blob_ticket`, `iroh_blobs_alpn`, `iroh_blobs_crate_version` as UniFFI surface. 5 cargo unit tests cover round-trip, garbage rejection, whitespace trimming, ALPN constant identity, and crate-version exposure.
- Cloud Functions: `MediaSessionEventDoc`, `MediaQuotaUsageDoc`, `MediaAttachmentManifestDoc`, `MediaSessionDailyRollupDoc`, `MediaBudgetStatusDoc` defined in `functions/src/types.ts`. Compile-only in Phase 1, no server writes yet.
- Documentation skeletons: this file, `docs/HERMES_MEDIA_TRANSPORT.md` (architecture spec), `docs/runbooks/media-quota.md`, `docs/runbooks/media-budget.md`, `docs/runbooks/media-device-matrix/README.md`. `docs/HERMES_IROH_TRANSPORT.md` extended with a "Media stream classes" section.
- Unit tests: 28 new tests in `OpenBurnBarMediaTests` covering codec round-trip + oversize rejection + truncation guards (both layers) + unknown-kind rejection + GOP boundary metadata, stream-class parse + phase availability + Codable round-trip, bitrate controller down-adapt + recovery hysteresis + ceiling + floor clamps, budget envelope normal/soft/hard transitions + Firestore wire format, capability-gate contract, and telemetry bucket boundary tests. Plus 5 cargo unit tests on the Rust side covering ticket round-trip, garbage rejection, whitespace trimming, ALPN constant identity, crate-version exposure. Existing 641 OpenBurnBarCore + IrohRelay tests still pass with 0 regressions from the frame protocol extension.

Blocked / pending (Phase 1b — integration):

- **Multi-ALPN endpoint router.** `IrohEndpointHandle::bootstrap` currently advertises a single ALPN (`openburnbar/1`). `publish_blob` and `fetch_blob` need the same `Endpoint` to serve `iroh_blobs::ALPN` alongside the chat ALPN — without that, a paired peer can negotiate a blob fetch but the local accept-loop refuses the stream. Implementation: wrap the `Endpoint` in an `iroh::protocol::Router` that dispatches by ALPN, install `BlobsProtocol::new(&store, endpoint, None)` for the blobs ALPN, keep the existing accept-loop on `openburnbar/1`. `iroh_blobs_alpn()` is already exposed for Swift to consume.
- **`publish_blob` + `fetch_blob` UniFFI methods on `IrohEndpointHandle`.** Once the router lands, `publish_blob(local_path) -> BlobTicketBytes` opens an `FsStore` rooted at the per-uid blob cache, calls `store.blobs().add_path(path).with_tag().await`, builds a `BlobTicket` from the resulting `Hash` + the endpoint's `NodeAddr`, returns the base32 surface form. `fetch_blob(ticket, dest, progress) -> BlobTransferStats` parses via `parse_blob_ticket`, dials `iroh_blobs::ALPN`, drives `iroh_blobs::get::request::get_blob` to write into `dest`, fills `BlobTransferStats`.
- **Re-spin `Vendor/OpenBurnBarIroh.xcframework`** via `scripts/build-iroh-xcframework.sh` after Phase 1b lands. The xcframework rebuild regenerates `OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift` with the new UniFFI surface; until then Swift sees only `parse_blob_ticket`, `iroh_blobs_alpn`, `iroh_blobs_crate_version` (the Phase 1a substrate).
- **Mac chat-input attachment entry** (hidden Cmd+Option+Click on `HermesDashboardChatPanel` per Phase 1 plan) — gated on the rebuilt xcframework.
- **iOS receive UI** (`UIDocumentPickerViewController` for non-image, `PHPhotoLibrary` for image MIME types) — gated on the rebuilt xcframework.
- **Manual TestFlight end-to-end**: real Mac (M3) on Wi-Fi → real iPhone 17 Pro on cellular, 5 MB PNG screenshot. `iroh_audit_events` should show `iroh_stream_opened` with `streamClass: "media.blob"` and `iroh_stream_closed` success; wall-clock < 15 s on 50 Mbps; zero plaintext crosses Firebase; Photos shows saved image with intact EXIF.

Next action:
- Implement the multi-ALPN router + `publish_blob`/`fetch_blob` (Phase 1b above), re-spin the xcframework, wire the Mac chat-input entry + iOS save sheet, flip `media_blob_transfer_enabled` on for Alberto's account, and run the manual TestFlight loop above.

---
