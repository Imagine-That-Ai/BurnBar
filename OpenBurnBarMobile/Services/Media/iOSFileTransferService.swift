import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

#if canImport(UIKit)
import UIKit
#endif

/// iOS-side file transfer driver. Mirror of `MacFileTransferService` but
/// inverted: the typical Phase 1 flow is **Mac → iOS**, so this class is
/// primarily a receiver. Sending iOS → Mac is a Phase 2 stretch.
///
/// Receive flow:
///   1. iOS sees `media.blob.advertise` on the active chat response
///      stream (the chat connection iOS dialed to Mac).
///   2. `HermesIrohRelayTransport` routes the frame to
///      `handleAdvertise(frame:ackSender:)`.
///   3. Service runs `MediaFileTransferService.fetch` to download the
///      blob into the per-blob inbox.
///   4. Service emits `media.blob.ack` back on the same chat stream.
///   5. UI surfaces (Phase 2) read the `lastReceivedManifest` publisher.
@MainActor
final class iOSFileTransferService: ObservableObject {
    /// Mercury Phase 8 — singleton accessor populated by `AppDelegate`
    /// after `configureMercuryFileTransfer()` builds the receiver. Lets
    /// the Mercury Live sheet drive outbound sends without threading
    /// the receiver through the SwiftUI tree.
    static var current: iOSFileTransferService?

    enum Failure: Error, LocalizedError {
        case backendUnavailable
        case fileMissing(URL)
        case publishFailed(String)
        case fetchFailed(String)
        case dispatchUnavailable
        case settingDisabled
        /// T-ATT-02/03 — the authoritative media gate refused the inbound transfer.
        case admissionDenied(String)
        /// T-ATT-06 — seal-at-rest could not run (no session key, or sealing
        /// failed). The plaintext blob is deleted and the transfer is refused
        /// rather than left as plaintext in the inbox.
        case sealAtRestUnavailable
        /// T-ATT-04 — the sender-bound manifest MAC did not verify; a relay may
        /// have tampered with the advertised manifest.
        case manifestUnverified

        var errorDescription: String? {
            switch self {
            case .backendUnavailable:
                return "Mercury file transfer is unavailable on this build."
            case .fileMissing(let url):
                return "File missing: \(url.path)"
            case .publishFailed(let message):
                return "Publish failed: \(message)"
            case .fetchFailed(let message):
                return "Fetch failed: \(message)"
            case .dispatchUnavailable:
                return "No active iroh stream is available."
            case .settingDisabled:
                return "media_blob_transfer_enabled is off."
            case .admissionDenied(let reason):
                return "media admission denied: \(reason)"
            case .sealAtRestUnavailable:
                return "This file could not be secured on this device, so it was not kept."
            case .manifestUnverified:
                return "This file could not be verified as coming from your paired device."
            }
        }
    }

    typealias AdvertiseSender = @MainActor (HermesRealtimeRelayFrame) async throws -> Void

    struct ReceivedAttachment: Identifiable, Equatable {
        let id: String
        let manifest: HermesRealtimeRelayAttachmentManifest
        let destinationURL: URL
        let stats: BlobTransferStats
    }

    /// Lightweight notification emitted from `sendFile` and
    /// `handleAdvertise` success paths so callers (today: the Mercury
    /// transfer-history store) can record a row without reaching into
    /// the service's `@Published` state. Stays out of `OpenBurnBarCore`
    /// — this is a UI concern.
    struct TransferCompletion: Sendable, Equatable {
        enum Direction: String, Sendable, Equatable {
            case sent
            case received
        }
        let id: String
        let connectionID: String
        let direction: Direction
        let filename: String
        let mime: String
        let sizeBytes: Int64
        let completedAt: Date
        let bytesPerSecond: Double?
        let didResume: Bool
        let localURL: URL?
    }

    private let service: MediaFileTransferService?
    private let settingsProvider: @MainActor () -> Bool
    /// T-ATT-02/03 — authoritative inbound media admission gate (entitlement +
    /// daily cap + kill switch + concurrency), mirroring `MacFileTransferService`.
    /// The advertised manifest size feeds the per-day byte cap so a transfer that
    /// would blow the budget is refused with a denial ack rather than fetched
    /// first. Defaults to `AlwaysAllowMediaCapabilityGate` for dev/loopback.
    private let capabilityGate: any MediaCapabilityGate
    /// T-ATT-06 — when a media-seal session key exists for the receiving
    /// connection, received blob bytes are sealed at rest (AES-256-GCM,
    /// manifest-bound AAD) instead of landing as plaintext in the inbox. Unlike
    /// the Mac path's "keep quarantine-only" fallback, iOS FAILS CLOSED when this
    /// returns nil: the plaintext is deleted and the transfer refused, because an
    /// iOS sandbox inbox has no quarantine xattr backstop.
    private let frameSealKeyProvider: @MainActor (_ uid: String, _ connectionID: String) -> SymmetricKey?
    /// T-ATT-04 — supplies the expected sender-bound MAC over
    /// `(blobHash,filename,mime,size)` for an inbound manifest, or nil when no MAC
    /// was advertised. When present it MUST verify under the media-seal key
    /// (`MercuryManifestMAC`) or the transfer is refused. nil-by-default keeps
    /// pre-MAC peers working until the wire carrier ships (Deferred portion).
    private let manifestMACProvider: @MainActor (_ frame: HermesRealtimeRelayFrame) -> String?
    private let frameSealAEAD = MediaFrameAEAD()
    /// T-ATT-06 rollout gate: when true (default), a received blob with no seal
    /// key is refused+deleted. A `UserDefaults` override lets QA exercise the
    /// legacy keep-plaintext path during migration.
    private let sealAtRestRequired: Bool
    /// Long-lived media control stream owners, keyed by Hermes connection.
    /// Set via `attachControlStream(_:connectionID:)` once iOS auth +
    /// Hermes connection reach an authenticated state. Optional so tests
    /// can drive the receive path without spinning up an iroh dialer.
    private var controlCoordinatorsByConnectionID: [String: MediaControlStreamCoordinator] = [:]

    @Published private(set) var lastError: Failure?
    @Published private(set) var inFlightCount: Int = 0
    @Published private(set) var lastReceivedAttachment: ReceivedAttachment?
    @Published private(set) var lastSentManifestID: String?

    /// Fires on every successful send + receive. Set by `AppDelegate`
    /// after the Mercury transfer-history store is wired up.
    var onTransferCompleted: ((TransferCompletion) -> Void)?

    init(
        service: MediaFileTransferService?,
        settingsProvider: @escaping @MainActor () -> Bool,
        capabilityGate: any MediaCapabilityGate = AlwaysAllowMediaCapabilityGate(),
        frameSealKeyProvider: @escaping @MainActor (_ uid: String, _ connectionID: String) -> SymmetricKey? = { _, _ in nil },
        manifestMACProvider: @escaping @MainActor (_ frame: HermesRealtimeRelayFrame) -> String? = { _ in nil },
        sealAtRestRequired: Bool = MercuryInboxSecurityPolicy.sealAtRestRequired()
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
        self.capabilityGate = capabilityGate
        self.frameSealKeyProvider = frameSealKeyProvider
        self.manifestMACProvider = manifestMACProvider
        self.sealAtRestRequired = sealAtRestRequired
    }

    func attachControlStream(_ coordinator: MediaControlStreamCoordinator, connectionID: String) {
        controlCoordinatorsByConnectionID[connectionID] = coordinator
    }

    func detachControlStream(connectionID: String? = nil) async {
        if let connectionID {
            guard let coordinator = controlCoordinatorsByConnectionID.removeValue(forKey: connectionID) else { return }
            await coordinator.stop()
            return
        }
        let coordinators = Array(controlCoordinatorsByConnectionID.values)
        controlCoordinatorsByConnectionID.removeAll()
        for coordinator in coordinators {
            await coordinator.stop()
        }
    }

    func bootstrapBlobEndpoint() async throws -> IrohEndpointIdentity {
        guard let service else { throw Failure.backendUnavailable }
        return try await service.bootstrap()
    }

    /// Phase 1 receive entry point. iOS sees a `media.blob.advertise` on
    /// the active chat response stream, calls in here, fetch happens,
    /// ack goes back on the same chat stream via `ackSender`.
    func handleAdvertise(
        frame: HermesRealtimeRelayFrame,
        ackSender: AdvertiseSender
    ) async {
        guard settingsProvider() else { return }
        guard let media = frame.media,
              let manifest = media.attachment,
              let ticket = media.blobTicket else {
            return
        }

        // T-ATT-02/03 — admit the inbound transfer through the authoritative gate
        // BEFORE touching the blob backend, exactly as `MacFileTransferService`
        // does. The advertised size feeds the per-day byte cap so a transfer that
        // would blow the budget is refused with a denial ack instead of fetched
        // first and charged after.
        let admission = await capabilityGate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: manifest.size
        )
        if case .denied(let denyReason) = admission {
            lastError = .admissionDenied(denyReason.rawValue)
            await sendAck(
                manifest: manifest,
                frame: frame,
                status: .rejected,
                reason: "media admission denied: \(denyReason.rawValue)",
                ackSender: ackSender
            )
            return
        }

        // T-ATT-04 — verify the sender-bound MAC over (blobHash,filename,mime,size)
        // when one was advertised. A missing MAC is tolerated for pre-MAC peers
        // (the wire carrier is the Deferred portion); a PRESENT-but-invalid MAC is
        // refused fail-closed, because that means the manifest was tampered with.
        if let expectedMAC = manifestMACProvider(frame) {
            guard let sealKey = frameSealKeyProvider(frame.uid, frame.connectionId),
                  MercuryManifestMAC.verify(expectedTagBase64: expectedMAC, manifest: manifest, key: sealKey) else {
                lastError = .manifestUnverified
                await sendAck(
                    manifest: manifest,
                    frame: frame,
                    status: .rejected,
                    reason: "manifest signature unverified",
                    ackSender: ackSender
                )
                return
            }
        }

        inFlightCount += 1
        defer { inFlightCount -= 1 }

        var status: HermesRealtimeRelayMediaAck.Status = .received
        var reason: String?

        do {
            guard let service else { throw Failure.backendUnavailable }
            let (destination, stats) = try await service.fetch(
                ticketText: ticket,
                manifest: manifest
            )
            // T-ATT-06 — seal the received bytes at rest under the media session
            // key. iOS FAILS CLOSED: if no key is available (and the policy
            // requires sealing), the plaintext is deleted and the transfer
            // refused, rather than left as plaintext in the sandbox inbox.
            try sealReceivedFileAtRest(at: destination, frame: frame, manifest: manifest)
            // T-ATT-02 — harden the at-rest file: complete data protection (key
            // evicted when the device locks) and exclude from iCloud/iTunes
            // backups so the inbox blob never leaves the device.
            try Self.applyInboundFileProtection(to: destination)
            lastReceivedAttachment = ReceivedAttachment(
                id: manifest.manifestId,
                manifest: manifest,
                destinationURL: destination,
                stats: stats
            )
            let bps: Double? = stats.durationMillis > 0
                ? Double(stats.bytesTotal) * 1000.0 / Double(stats.durationMillis)
                : nil
            onTransferCompleted?(TransferCompletion(
                id: manifest.manifestId,
                connectionID: frame.connectionId,
                direction: .received,
                filename: manifest.filename,
                mime: manifest.mime,
                sizeBytes: manifest.size,
                completedAt: Date(),
                bytesPerSecond: bps,
                didResume: stats.didResume,
                localURL: destination
            ))
        } catch let failure as Failure {
            status = .rejected
            reason = failure.errorDescription
            lastError = failure
        } catch let serviceError as MediaFileTransferService.ServiceError {
            status = .rejected
            reason = String(describing: serviceError)
            lastError = .fetchFailed(reason ?? "")
        } catch {
            status = .rejected
            reason = error.localizedDescription
            lastError = .fetchFailed(reason ?? "")
        }

        let ack = HermesRealtimeRelayMediaAck(
            manifestId: manifest.manifestId,
            status: status,
            reason: reason
        )
        let ackFrame = HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                ack: ack
            )
        )
        try? await ackSender(ackFrame)
    }

    /// Send a `media.blob.ack` for a manifest. Used by the denial/refusal paths so
    /// the peer sees the same shape it would for a fetch failure, rather than a
    /// silently dropped advertise.
    private func sendAck(
        manifest: HermesRealtimeRelayAttachmentManifest,
        frame: HermesRealtimeRelayFrame,
        status: HermesRealtimeRelayMediaAck.Status,
        reason: String?,
        ackSender: AdvertiseSender
    ) async {
        let ack = HermesRealtimeRelayMediaAck(
            manifestId: manifest.manifestId,
            status: status,
            reason: reason
        )
        let ackFrame = HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                ack: ack
            )
        )
        try? await ackSender(ackFrame)
    }

    /// T-ATT-06 — seal the freshly-fetched plaintext blob in place with its
    /// `MediaFrameAEAD` (OBMFA1) envelope under the media session key. Unlike the
    /// Mac path (which keeps quarantine-only plaintext when no key exists), iOS
    /// FAILS CLOSED: when no key is available and the policy requires sealing, the
    /// plaintext is deleted and the transfer refused, so the sandbox inbox never
    /// holds an unsealed blob. The write goes through a sibling temp file + atomic
    /// replace so a crash mid-seal never leaves a truncated file.
    private func sealReceivedFileAtRest(
        at url: URL,
        frame: HermesRealtimeRelayFrame,
        manifest: HermesRealtimeRelayAttachmentManifest
    ) throws {
        guard let sealKey = frameSealKeyProvider(frame.uid, frame.connectionId) else {
            guard sealAtRestRequired else { return }
            // No key and sealing required — refuse and remove the plaintext.
            try? FileManager.default.removeItem(at: url)
            throw Failure.sealAtRestUnavailable
        }
        let plaintext: Data
        do {
            plaintext = try Data(contentsOf: url)
        } catch {
            throw Failure.sealAtRestUnavailable
        }
        // Already sealed (idempotent re-fetch) — leave it.
        guard !MediaFrameAEAD.isSealedEnvelope(plaintext) else { return }
        let sealed: Data
        do {
            sealed = try frameSealAEAD.seal(
                plaintext: plaintext,
                key: sealKey,
                streamClass: MediaStreamClass.blob.rawValue,
                kind: 0,
                gopID: Self.atRestGopID(for: manifest),
                frameIndex: 0
            )
        } catch {
            // Sealing failed — never keep the plaintext.
            try? FileManager.default.removeItem(at: url)
            throw Failure.sealAtRestUnavailable
        }
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).obmfa1-tmp")
        do {
            try sealed.write(to: tempURL, options: [.atomic, .completeFileProtection])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: url)
            throw Failure.sealAtRestUnavailable
        }
    }

    /// Stable 32-bit AAD discriminator derived from the manifest id so the at-rest
    /// seal is bound to this exact transfer (mirrors `MacFileTransferService`).
    static func atRestGopID(for manifest: HermesRealtimeRelayAttachmentManifest) -> UInt32 {
        var hash: UInt32 = 2_166_136_261 // FNV-1a offset basis
        for byte in manifest.manifestId.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    /// T-ATT-02 — apply `FileProtectionType.complete` and exclude the file from
    /// backups. Complete protection evicts the file's key when the device locks;
    /// excluding from backup keeps the inbox blob from leaving the device via
    /// iCloud/iTunes. Both are best-effort hardening on top of the at-rest seal.
    private static func applyInboundFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    /// Publish a file from iOS and emit a `media.blob.advertise` frame
    /// to Mac. Resolution order:
    ///   1. Explicit `advertiseSender` override (tests).
    ///   2. The persistent media-control coordinator (production).
    ///   3. `.dispatchUnavailable` failure — never silently drops a
    ///      user-initiated send.
    func sendFile(
        at fileURL: URL,
        uid: String,
        connectionID: String,
        peerDeviceID: String?,
        advertiseSender: AdvertiseSender? = nil
    ) async throws -> HermesRealtimeRelayAttachmentManifest {
        guard settingsProvider() else { throw Failure.settingDisabled }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Failure.fileMissing(fileURL)
        }

        inFlightCount += 1
        defer { inFlightCount -= 1 }

        let publishStart = Date()
        let publish: MediaFileTransferService.PublishResult
        do {
            guard let service else { throw Failure.backendUnavailable }
            publish = try await service.publish(localFile: fileURL, peerDeviceID: peerDeviceID)
        } catch let failure as Failure {
            lastError = failure
            throw failure
        } catch let serviceError as MediaFileTransferService.ServiceError {
            let failure = Failure.publishFailed(String(describing: serviceError))
            lastError = failure
            throw failure
        }

        let frame = HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: uid,
            connectionId: connectionID,
            requestId: publish.manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: publish.manifest,
                blobTicket: publish.ticketText
            )
        )

        do {
            if let advertiseSender {
                try await advertiseSender(frame)
            } else if let controlCoordinator = controlCoordinatorsByConnectionID[connectionID] {
                try await controlCoordinator.send(frame: frame)
            } else {
                lastError = .dispatchUnavailable
                throw Failure.dispatchUnavailable
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            let failure = Failure.publishFailed("advertise emit: \(error.localizedDescription)")
            lastError = failure
            throw failure
        }

        lastSentManifestID = publish.manifest.manifestId

        let elapsed = Date().timeIntervalSince(publishStart)
        let bps: Double? = elapsed > 0 ? Double(publish.manifest.size) / elapsed : nil
        onTransferCompleted?(TransferCompletion(
            id: publish.manifest.manifestId,
            connectionID: connectionID,
            direction: .sent,
            filename: publish.manifest.filename,
            mime: publish.manifest.mime,
            sizeBytes: publish.manifest.size,
            completedAt: Date(),
            bytesPerSecond: bps,
            didResume: false,
            localURL: fileURL
        ))

        return publish.manifest
    }
}

/// T-ATT-06 — rollout gate for fail-closed seal-at-rest of received Mercury
/// blobs. Default **on**: a received file with no media-seal session key is
/// refused and deleted rather than kept as plaintext in the sandbox inbox. A
/// `UserDefaults` override lets QA / emergency rollback exercise the legacy
/// keep-plaintext path without a code change.
enum MercuryInboxSecurityPolicy {
    static let userDefaultsKey = "openburnbar.mercuryInbox.sealAtRestRequired.enabled"

    nonisolated(unsafe) static var defaultEnabled = true

    static func sealAtRestRequired(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: userDefaultsKey) != nil {
            return defaults.bool(forKey: userDefaultsKey)
        }
        return defaultEnabled
    }
}
