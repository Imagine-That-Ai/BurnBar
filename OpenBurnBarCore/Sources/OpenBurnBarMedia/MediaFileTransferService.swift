import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Transport-agnostic Mercury file transfer driver. Sits between the
/// platform-specific FileTransferService classes (Mac + iOS) and the
/// underlying `IrohBlobBackend`. Holds no platform-specific imports — the
/// Mac and iOS adapters provide their own attachment-saver, manifest-store,
/// and chat-stream emitter.
///
/// Responsibility split:
///
/// - This service: bootstrap the blob node, hash + publish a local file
///   (returning the ticket + manifest), fetch a peer's ticket into a
///   destination path.
/// - Mac/iOS adapter: drive the chat-stream side of the protocol — emit
///   `media.blob.advertise` after a publish, dispatch incoming
///   `media.blob.advertise` to a fetch, emit `media.blob.ack` after the
///   transfer settles. Persist `MediaAttachmentManifest` records.
public actor MediaFileTransferService {
    public enum ServiceError: Error, Equatable, Sendable {
        case backendUnavailable
        case notBootstrapped
        case publishFailed(String)
        case fetchFailed(String)
        case localFileMissing(String)
        case invalidTicket(String)
    }

    public struct Configuration: Sendable {
        public let storeDirectoryURL: URL
        public let inboxDirectoryURL: URL
        public let secretKeyProvider: @Sendable () throws -> Data
        public let relayURL: String?

        public init(
            storeDirectoryURL: URL,
            inboxDirectoryURL: URL,
            secretKeyProvider: @escaping @Sendable () throws -> Data,
            relayURL: String? = nil
        ) {
            self.storeDirectoryURL = storeDirectoryURL
            self.inboxDirectoryURL = inboxDirectoryURL
            self.secretKeyProvider = secretKeyProvider
            self.relayURL = relayURL
        }
    }

    public struct PublishResult: Sendable, Equatable {
        public let manifest: HermesRealtimeRelayAttachmentManifest
        public let ticketText: String

        public init(manifest: HermesRealtimeRelayAttachmentManifest, ticketText: String) {
            self.manifest = manifest
            self.ticketText = ticketText
        }
    }

    private let backend: IrohBlobBackend
    private let configuration: Configuration
    private var bootstrapTask: Task<IrohEndpointIdentity, Error>?
    private var bootstrappedIdentity: IrohEndpointIdentity?

    public init(backend: IrohBlobBackend, configuration: Configuration) {
        self.backend = backend
        self.configuration = configuration
    }

    /// Idempotently bring up the blob endpoint. Concurrent callers reuse
    /// the same in-flight bootstrap rather than racing two endpoints.
    @discardableResult
    public func bootstrap() async throws -> IrohEndpointIdentity {
        if let identity = bootstrappedIdentity {
            return identity
        }
        if let pending = bootstrapTask {
            return try await pending.value
        }

        let task = Task<IrohEndpointIdentity, Error> { [backend, configuration] in
            try Self.ensureDirectoryExists(configuration.storeDirectoryURL)
            try Self.ensureDirectoryExists(configuration.inboxDirectoryURL)
            let secret = try configuration.secretKeyProvider()
            return try await backend.bootstrap(
                secret: secret,
                storeDirectoryPath: configuration.storeDirectoryURL.path,
                relayURL: configuration.relayURL
            )
        }
        bootstrapTask = task
        defer { bootstrapTask = nil }

        let identity = try await task.value
        bootstrappedIdentity = identity
        return identity
    }

    /// Publish a local file as a content-addressed blob. Returns the
    /// ticket text + the wire-form manifest to attach to the
    /// `media.blob.advertise` frame.
    public func publish(
        localFile fileURL: URL,
        peerDeviceID: String?
    ) async throws -> PublishResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ServiceError.localFileMissing(fileURL.path)
        }
        _ = try await bootstrap()

        let ticketText: String
        do {
            ticketText = try await backend.publishBlob(localPath: fileURL.path)
        } catch let blobError as IrohBlobBackendError {
            throw ServiceError.publishFailed(String(describing: blobError))
        }

        let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(0)
        let mime = Self.inferMime(for: fileURL)
        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_" + UUID().uuidString.lowercased(),
            blobHash: ticketText,
            filename: fileURL.lastPathComponent,
            mime: mime,
            size: size,
            peerDeviceId: peerDeviceID,
            createdAt: Date()
        )
        return PublishResult(manifest: manifest, ticketText: ticketText)
    }

    /// Fetch a peer's blob into the inbox directory and return the
    /// destination URL + transfer stats. Filename: `<blobHash>.<ext>` so
    /// the platform adapter can locate it.
    public func fetch(
        ticketText: String,
        manifest: HermesRealtimeRelayAttachmentManifest
    ) async throws -> (destinationURL: URL, stats: BlobTransferStats) {
        _ = try await bootstrap()

        let inboxFile = inboxURL(for: manifest)

        do {
            let stats = try await backend.fetchBlob(
                ticketText: ticketText,
                destination: inboxFile.path
            )
            return (inboxFile, stats)
        } catch let blobError as IrohBlobBackendError {
            throw ServiceError.fetchFailed(String(describing: blobError))
        }
    }

    /// Tear down the underlying blob endpoint. Idempotent.
    public func shutdown() async {
        bootstrappedIdentity = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        await backend.shutdown()
    }

    private func inboxURL(for manifest: HermesRealtimeRelayAttachmentManifest) -> URL {
        let safeExt = (manifest.filename as NSString).pathExtension
        var name = manifest.blobHash.replacingOccurrences(of: "/", with: "_")
        if !safeExt.isEmpty {
            name += "." + safeExt
        }
        return configuration.inboxDirectoryURL.appendingPathComponent(name)
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private static func inferMime(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "log": return "text/plain"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
