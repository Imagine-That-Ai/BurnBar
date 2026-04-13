@testable import OpenBurnBarCore
import XCTest

final class ChromeProfileDiscoveryTests: XCTestCase {
    func test_detectServiceIdentity_detectsOpenAISessionWithoutAccountLabel() throws {
        let tempDir = try makeStorageDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("000001.ldb")
        try "https://auth.openai.com session active".write(to: file, atomically: true, encoding: .utf8)

        let identity = ChromeProfileDiscovery.detectServiceIdentity(
            provider: .openAI,
            candidateFiles: [file.path]
        )

        XCTAssertEqual(identity?.provider, .openAI)
        XCTAssertNil(identity?.accountLabel)
    }

    func test_detectServiceIdentity_extractsAccountEmailFromContext() throws {
        let tempDir = try makeStorageDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("000002.ldb")
        let payload = #"{"origin":"https://claude.ai","email":"work@acme.dev","status":"authenticated"}"#
        try payload.write(to: file, atomically: true, encoding: .utf8)

        let identity = ChromeProfileDiscovery.detectServiceIdentity(
            provider: .claude,
            candidateFiles: [file.path]
        )

        XCTAssertEqual(identity?.provider, .claude)
        XCTAssertEqual(identity?.accountLabel, "work@acme.dev")
    }

    func test_detectServiceIdentities_scansProfileStorageForMultipleProviders() throws {
        let profileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-profile-discovery-\(UUID().uuidString)", isDirectory: true)
        let leveldbDir = profileDir.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: leveldbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profileDir) }

        try #"{"origin":"https://auth.openai.com","email":"openai@acme.dev"}"#
            .write(to: leveldbDir.appendingPathComponent("000003.ldb"), atomically: true, encoding: .utf8)
        try #"{"origin":"https://claude.ai","email":"claude@acme.dev"}"#
            .write(to: leveldbDir.appendingPathComponent("000004.ldb"), atomically: true, encoding: .utf8)

        let identities = ChromeProfileDiscovery.detectServiceIdentities(profileDirectoryPath: profileDir.path)

        XCTAssertEqual(
            Set(identities.map(\.provider)),
            Set([.openAI, .claude])
        )
        XCTAssertTrue(identities.contains(where: { $0.provider == .openAI && $0.accountLabel == "openai@acme.dev" }))
        XCTAssertTrue(identities.contains(where: { $0.provider == .claude && $0.accountLabel == "claude@acme.dev" }))
    }

    private func makeStorageDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
