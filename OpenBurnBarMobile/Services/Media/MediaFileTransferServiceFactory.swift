import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Wires up the platform-agnostic `MediaFileTransferService` for the iOS
/// client. iOS-specific bits: sandbox-scoped Caches/MediaInbox path
/// (matches the plan § Phase 1 contract), and the iOS-side blob secret
/// store.
@MainActor
enum MediaFileTransferServiceFactory {
    static func make(
        backendOverride: IrohBlobBackend? = nil,
        relayURL: String? = nil
    ) -> MediaFileTransferService? {
        guard let backend = backendOverride ?? OpenBurnBarIrohBlobFFIBackendFactory.make() else {
            return nil
        }

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cachesURL = library.appendingPathComponent("Caches", isDirectory: true)
        let mercuryRoot = cachesURL.appendingPathComponent("Mercury", isDirectory: true)
        let storeURL = mercuryRoot.appendingPathComponent("BlobStore", isDirectory: true)
        let inboxURL = mercuryRoot.appendingPathComponent("MediaInbox", isDirectory: true)

        let configuration = MediaFileTransferService.Configuration(
            storeDirectoryURL: storeURL,
            inboxDirectoryURL: inboxURL,
            secretKeyProvider: {
                try IrohBlobKeyStore.shared.secretKeyMaterial().raw
            },
            relayURL: relayURL
        )
        return MediaFileTransferService(backend: backend, configuration: configuration)
    }
}
