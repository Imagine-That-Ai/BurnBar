import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Wires up the platform-agnostic `MediaFileTransferService` for the Mac
/// host. Encapsulates: blob secret resolution, store/inbox URL conventions
/// (sandbox-scoped Caches), and the relay-URL handoff from
/// `SettingsManager`.
@MainActor
enum MediaFileTransferServiceFactory {
    static func make(
        backendOverride: IrohBlobBackend? = nil,
        relayURL: String? = nil
    ) -> MediaFileTransferService? {
        guard let backend = backendOverride ?? OpenBurnBarIrohBlobFFIBackendFactory.make() else {
            return nil
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let mercuryRoot = caches.appendingPathComponent("Mercury", isDirectory: true)
        let storeURL = mercuryRoot.appendingPathComponent("BlobStore", isDirectory: true)
        let inboxURL = mercuryRoot.appendingPathComponent("Inbox", isDirectory: true)

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
