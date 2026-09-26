import Foundation
import OpenBurnBarIrohRelay

/// Wave 3.4 union of the macOS / iOS `MediaFileTransferServiceFactory`
/// twins. Wires up the platform-agnostic `MediaFileTransferService`:
/// blob-secret resolution, store/inbox URL conventions, and the relay-URL
/// handoff.
///
/// The two hosts differ only in sandbox layout (macOS:
/// `Caches/Mercury/{BlobStore,Inbox}`; iOS:
/// `Library/Caches/Mercury/{BlobStore,MediaInbox}`) and in which Keychain
/// entry holds the blob secret. The layout branch is `#if os(iOS)`; the
/// secret stays host-injected because both `IrohBlobKeyStore` backs are
/// platform Keychain code that cannot move into Core.
public enum MediaFileTransferServiceFactory {
    public static func make(
        backendOverride: IrohBlobBackend? = nil,
        relayURL: String? = nil,
        secretKeyProvider: @escaping @Sendable () throws -> Data
    ) -> MediaFileTransferService? {
        guard let backend = backendOverride ?? OpenBurnBarIrohBlobFFIBackendFactory.make() else {
            return nil
        }

        #if os(iOS)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cachesURL = library.appendingPathComponent("Caches", isDirectory: true)
        let mercuryRoot = cachesURL.appendingPathComponent("Mercury", isDirectory: true)
        let storeURL = mercuryRoot.appendingPathComponent("BlobStore", isDirectory: true)
        let inboxURL = mercuryRoot.appendingPathComponent("MediaInbox", isDirectory: true)
        #else
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let mercuryRoot = caches.appendingPathComponent("Mercury", isDirectory: true)
        let storeURL = mercuryRoot.appendingPathComponent("BlobStore", isDirectory: true)
        let inboxURL = mercuryRoot.appendingPathComponent("Inbox", isDirectory: true)
        #endif

        let configuration = MediaFileTransferService.Configuration(
            storeDirectoryURL: storeURL,
            inboxDirectoryURL: inboxURL,
            secretKeyProvider: secretKeyProvider,
            relayURL: relayURL
        )
        return MediaFileTransferService(backend: backend, configuration: configuration)
    }
}
