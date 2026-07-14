#if os(Linux)
import Foundation
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarLinuxPrivacyServiceTests: XCTestCase {
    private var directory: URL!
    private var routeURL: URL { directory.appendingPathComponent("proxy-route-events.jsonl") }
    private var expansionURL: URL { directory.appendingPathComponent("text-expansion-v1.obbsealed") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testInventoryAndPreviewExposeMetadataOnlyAndExecuteIsIdempotent() async throws {
        try Data("{\"secretModel\":\"do-not-return\"}\n".utf8).write(to: routeURL)
        try Data("sealed-secret-body".utf8).write(to: expansionURL)
        try setPrivate(routeURL)
        try setPrivate(expansionURL)

        let service = BurnBarLinuxPrivacyService(supportDirectory: directory)
        let inventory = await service.inventory(now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(inventory.stores.map(\.state), [.ready, .ready])
        XCTAssertEqual(inventory.stores.map(\.bytes), [32, 18])

        let preview = try await service.previewDeletion(
            stores: [.proxyRouteLog, .textExpansionStore],
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(preview.confirmationPhrase, BurnBarLinuxPrivacyService.confirmationPhrase)
        XCTAssertFalse(preview.token.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        XCTAssertFalse(encoded.contains(directory.path))
        XCTAssertFalse(encoded.contains("do-not-return"))
        XCTAssertFalse(encoded.contains("sealed-secret-body"))

        let request = BurnBarLinuxPrivacyService.DeletionRequest(
            token: preview.token,
            stores: preview.stores,
            confirmation: preview.confirmationPhrase
        )
        let result = try await service.executeDeletion(request, now: Date(timeIntervalSince1970: 11))
        XCTAssertEqual(result.deleted, [.proxyRouteLog, .textExpansionStore])
        XCTAssertEqual(result.alreadyAbsent, [])
        XCTAssertEqual(result.bytesRemoved, 50)
        XCTAssertFalse(result.idempotent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: routeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansionURL.path))

        let repeated = try await service.executeDeletion(request, now: Date(timeIntervalSince1970: 12))
        XCTAssertTrue(repeated.idempotent)
        XCTAssertEqual(repeated.deleted, result.deleted)
        XCTAssertEqual(repeated.bytesRemoved, result.bytesRemoved)
    }

    func testConfirmationAndScopeAreBoundToPreview() async throws {
        try Data("route".utf8).write(to: routeURL)
        try setPrivate(routeURL)
        let service = BurnBarLinuxPrivacyService(supportDirectory: directory)
        let preview = try await service.previewDeletion(stores: [.proxyRouteLog], now: Date())

        let wrongPhrase = BurnBarLinuxPrivacyService.DeletionRequest(
            token: preview.token,
            stores: preview.stores,
            confirmation: "DELETE EVERYTHING"
        )
        await XCTAssertThrowsErrorAsync(try await service.executeDeletion(wrongPhrase)) {
            XCTAssertEqual($0 as? BurnBarLinuxPrivacyService.ServiceError, .confirmationRequired)
        }

        let wrongScope = BurnBarLinuxPrivacyService.DeletionRequest(
            token: preview.token,
            stores: [.textExpansionStore],
            confirmation: preview.confirmationPhrase
        )
        await XCTAssertThrowsErrorAsync(try await service.executeDeletion(wrongScope)) {
            XCTAssertEqual($0 as? BurnBarLinuxPrivacyService.ServiceError, .scopeMismatch)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: routeURL.path))
    }

    func testSymlinkIsBlockedAndOutsideFileSurvives() async throws {
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("openburnbar-privacy-outside-\(UUID().uuidString)")
        try Data("outside-secret".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: routeURL, withDestinationURL: outside)

        let service = BurnBarLinuxPrivacyService(supportDirectory: directory)
        let inventory = await service.inventory()
        XCTAssertEqual(inventory.stores.first(where: { $0.store == .proxyRouteLog })?.state, .blocked)
        XCTAssertThrowsError(try await service.previewDeletion(stores: [.proxyRouteLog])) {
            XCTAssertEqual($0 as? BurnBarLinuxPrivacyService.ServiceError, .unsafeFile)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try String(contentsOf: outside), "outside-secret")
    }

    func testChangedStoreInvalidatesPreviewAndExpiryIsFailClosed() async throws {
        try Data("before".utf8).write(to: routeURL)
        try setPrivate(routeURL)
        let service = BurnBarLinuxPrivacyService(supportDirectory: directory, previewLifetime: 2)
        let preview = try await service.previewDeletion(stores: [.proxyRouteLog], now: Date(timeIntervalSince1970: 100))
        try Data("after".utf8).write(to: routeURL, options: .atomic)
        try setPrivate(routeURL)
        let changedRequest = BurnBarLinuxPrivacyService.DeletionRequest(
            token: preview.token,
            stores: preview.stores,
            confirmation: preview.confirmationPhrase
        )
        XCTAssertThrowsError(
            try await service.executeDeletion(changedRequest, now: Date(timeIntervalSince1970: 101))
        ) { XCTAssertEqual($0 as? BurnBarLinuxPrivacyService.ServiceError, .stalePreview) }
        XCTAssertEqual(try String(contentsOf: routeURL), "after")

        let expiring = try await service.previewDeletion(stores: [.proxyRouteLog], now: Date(timeIntervalSince1970: 200))
        let request = BurnBarLinuxPrivacyService.DeletionRequest(
            token: expiring.token,
            stores: expiring.stores,
            confirmation: expiring.confirmationPhrase
        )
        XCTAssertThrowsError(
            try await service.executeDeletion(request, now: Date(timeIntervalSince1970: 203))
        ) { XCTAssertEqual($0 as? BurnBarLinuxPrivacyService.ServiceError, .expiredPreview) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: routeURL.path))
    }

    func testEncryptedExportIsBoundedOwnerOnlyAndContainsNoPlaintextOnDisk() async throws {
        let routeSecret = "route-secret-that-must-not-be-plain"
        try Data("{\"secret\":\"\(routeSecret)\"}\n".utf8).write(to: routeURL)
        try Data("sealed-expansion-secret".utf8).write(to: expansionURL)
        try setPrivate(routeURL)
        try setPrivate(expansionURL)
        let destination = directory.appendingPathComponent("privacy-export.obb")
        let service = BurnBarLinuxPrivacyService(supportDirectory: directory)
        let response = try await service.export(
            BurnBarLinuxPrivacyExportRequest(
                stores: [.proxyRouteLog, .textExpansionStore],
                destinationPath: destination.path,
                passphrase: "correct horse battery"
            ),
            now: Date(timeIntervalSince1970: 50)
        )

        XCTAssertEqual(response.stores, [.proxyRouteLog, .textExpansionStore])
        XCTAssertEqual(response.formatVersion, Int(BurnBarLinuxPrivacyExportCrypto.formatVersion))
        XCTAssertEqual(response.byteCount, Int64(try Data(contentsOf: destination).count))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let bundle = try Data(contentsOf: destination)
        let raw = String(decoding: bundle, as: UTF8.self)
        XCTAssertFalse(raw.contains(routeSecret))
        XCTAssertFalse(raw.contains("sealed-expansion-secret"))
        let payload = try BurnBarLinuxPrivacyExportCrypto.open(bundle: bundle, passphrase: "correct horse battery")
        let plaintext = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(plaintext.contains(routeSecret))
        XCTAssertTrue(plaintext.contains("sealed-expansion-secret"))
    }

    func testExportRejectsUnsafeDestinationAndWeakPassphrase() async throws {
        try Data("route".utf8).write(to: routeURL)
        try setPrivate(routeURL)
        let service = BurnBarLinuxPrivacyService(supportDirectory: directory)
        let unsafe = BurnBarLinuxPrivacyExportRequest(
            stores: [.proxyRouteLog],
            destinationPath: "/tmp/../etc/privacy-export.obb",
            passphrase: "correct horse battery"
        )
        await XCTAssertThrowsErrorAsync(try await service.export(unsafe)) {
            XCTAssertEqual($0 as? BurnBarLinuxPrivacyService.ServiceError, .unsafeLocation)
        }

        let weak = BurnBarLinuxPrivacyExportRequest(
            stores: [.proxyRouteLog],
            destinationPath: directory.appendingPathComponent("weak.obb").path,
            passphrase: "short"
        )
        await XCTAssertThrowsErrorAsync(try await service.export(weak)) {
            guard case .exportCrypto(.passphraseTooShort) = $0 as? BurnBarLinuxPrivacyService.ServiceError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    private func setPrivate(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ handler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            handler(error)
        }
    }
}
#endif
