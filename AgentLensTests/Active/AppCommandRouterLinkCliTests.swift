#if canImport(AppKit)
import AppKit
import Foundation
import XCTest
@testable import OpenBurnBar

/// F1 — `openburnbar://link-cli` exports the Cloud Vault key (which decrypts
/// ALL synced E2E content) into the CLI keychain item, and the URL scheme is
/// reachable by any local process. These tests pin the full security-gate
/// matrix through the router's injection seams: every gate must fail CLOSED
/// (no key read, no keychain write) and the export happens only after an
/// explicit confirmation AND a device-owner authentication success.
@MainActor
final class AppCommandRouterLinkCliTests: XCTestCase {

    private struct ExportError: Error {}

    private final class Recorder {
        var alerts: [(style: NSAlert.Style, title: String)] = []
        var confirmationRequests = 0
        var authenticationRequests = 0
        var loadedUIDs: [String] = []
        var keychainWrites: [Data] = []
        var legacyRemovals = 0
    }

    private func makeRouter(
        uid: String? = "uid-link",
        confirm: Bool = true,
        authOutcome: AppCommandRouter.LinkCliAuthOutcome = .authenticated,
        keyData: Data? = Data("vault-key-bytes".utf8),
        loaderError: Error? = nil,
        recorder: Recorder
    ) -> AppCommandRouter {
        let router = AppCommandRouter()
        router.linkCliUserIDProvider = { uid }
        router.linkCliConfirmationPresenter = {
            recorder.confirmationRequests += 1
            return confirm
        }
        router.linkCliDeviceOwnerAuthenticator = { completion in
            recorder.authenticationRequests += 1
            completion(authOutcome)
        }
        router.linkCliAlertPresenter = { style, title, _ in
            recorder.alerts.append((style, title))
        }
        router.linkCliVaultKeyLoader = { uid in
            recorder.loadedUIDs.append(uid)
            if let loaderError { throw loaderError }
            return keyData
        }
        router.linkCliKeychainWriter = { data in
            recorder.keychainWrites.append(data)
        }
        router.linkCliLegacyFallbackRemover = {
            recorder.legacyRemovals += 1
        }
        return router
    }

    // MARK: - URL recognition

    func test_linkCliURLRoutesIntoTheGatedFlow() {
        let recorder = Recorder()
        let router = makeRouter(recorder: recorder)
        XCTAssertTrue(router.handle(URL(string: "openburnbar://link-cli")!))
        XCTAssertEqual(recorder.confirmationRequests, 1)
        XCTAssertEqual(recorder.keychainWrites.count, 1)
    }

    func test_nonOpenBurnBarSchemeIsNotHandled() {
        let recorder = Recorder()
        let router = makeRouter(recorder: recorder)
        XCTAssertFalse(router.handle(URL(string: "https://example.com/link-cli")!))
        XCTAssertEqual(recorder.confirmationRequests, 0)
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
    }

    // MARK: - Gate 0: signed in

    func test_signedOutShowsGuidanceAndNeverTouchesTheKey() {
        let recorder = Recorder()
        let router = makeRouter(uid: nil, recorder: recorder)

        XCTAssertTrue(router.handleLinkCli(), "recognized URL must not fall through to a generic handler")
        XCTAssertEqual(recorder.alerts.map(\.title), ["Sign In Required"])
        XCTAssertEqual(recorder.confirmationRequests, 0, "no confirmation before sign-in")
        XCTAssertEqual(recorder.authenticationRequests, 0)
        XCTAssertTrue(recorder.loadedUIDs.isEmpty, "the vault key must never be read")
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
    }

    // MARK: - Gate 1: explicit confirmation

    func test_declinedConfirmationAbortsSilentlyWithoutAuthOrExport() {
        let recorder = Recorder()
        let router = makeRouter(confirm: false, recorder: recorder)

        XCTAssertTrue(router.handleLinkCli())
        XCTAssertEqual(recorder.confirmationRequests, 1)
        XCTAssertEqual(recorder.authenticationRequests, 0, "declining must not even prompt Touch ID")
        XCTAssertTrue(recorder.loadedUIDs.isEmpty)
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
        XCTAssertTrue(recorder.alerts.isEmpty, "a drive-by probe learns nothing from a cancel")
    }

    // MARK: - Gate 2: device-owner authentication

    func test_unavailableDeviceOwnerAuthFailsClosed() {
        let recorder = Recorder()
        let router = makeRouter(authOutcome: .unavailable, recorder: recorder)

        XCTAssertTrue(router.handleLinkCli())
        XCTAssertEqual(recorder.alerts.map(\.title), ["Linking Unavailable"])
        XCTAssertEqual(recorder.alerts.first?.style, .critical)
        XCTAssertTrue(recorder.loadedUIDs.isEmpty, "no key read without an identity check")
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
    }

    func test_deniedDeviceOwnerAuthFailsClosed() {
        let recorder = Recorder()
        let router = makeRouter(authOutcome: .denied, recorder: recorder)

        XCTAssertTrue(router.handleLinkCli())
        XCTAssertEqual(recorder.alerts.map(\.title), ["Linking Cancelled"])
        XCTAssertEqual(recorder.alerts.first?.style, .warning)
        XCTAssertTrue(recorder.loadedUIDs.isEmpty)
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
    }

    // MARK: - Export outcomes (after both gates pass)

    func test_successfulExportWritesBase64KeyAndRemovesLegacyFallback() {
        let recorder = Recorder()
        let keyData = Data("vault-key-bytes".utf8)
        let router = makeRouter(keyData: keyData, recorder: recorder)

        XCTAssertTrue(router.handleLinkCli())
        XCTAssertEqual(recorder.confirmationRequests, 1)
        XCTAssertEqual(recorder.authenticationRequests, 1)
        XCTAssertEqual(recorder.loadedUIDs, ["uid-link"])
        // The CLI keychain item stores the UTF-8 bytes of the base64 key.
        XCTAssertEqual(recorder.keychainWrites, [Data(keyData.base64EncodedString().utf8)])
        XCTAssertEqual(recorder.legacyRemovals, 1, "the plaintext on-disk fallback must be cleaned up")
        XCTAssertEqual(recorder.alerts.map(\.title), ["CLI Linked Successfully!"])
        XCTAssertEqual(recorder.alerts.first?.style, .informational)
    }

    func test_missingVaultKeyShowsGuidanceWithoutKeychainWrite() {
        let recorder = Recorder()
        let router = makeRouter(keyData: nil, recorder: recorder)

        XCTAssertTrue(router.handleLinkCli())
        XCTAssertEqual(recorder.alerts.map(\.title), ["No Vault Key Found"])
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
        XCTAssertEqual(recorder.legacyRemovals, 0)
    }

    func test_loaderFailureSurfacesLinkingFailedWithoutKeychainWrite() {
        let recorder = Recorder()
        let router = makeRouter(loaderError: ExportError(), recorder: recorder)

        XCTAssertTrue(router.handleLinkCli())
        XCTAssertEqual(recorder.alerts.map(\.title), ["Linking Failed"])
        XCTAssertEqual(recorder.alerts.first?.style, .critical)
        XCTAssertTrue(recorder.keychainWrites.isEmpty)
        XCTAssertEqual(recorder.legacyRemovals, 0)
    }
}
#endif
