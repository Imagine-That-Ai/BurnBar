import XCTest
@testable import OpenBurnBarCore
#if os(Linux)
import OpenBurnBarLinuxSecurity
#endif

#if os(Linux)
final class OpenBurnBarCoreLinuxPathContractTests: XCTestCase {
    func testLinuxPathsPreferXDGRuntimeSocket() {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
        let socket = OpenBurnBarLinuxPaths.defaultDaemonSocketURL()
        if let runtime, !runtime.isEmpty {
            XCTAssertTrue(
                socket.path.hasPrefix(runtime),
                "expected socket under XDG_RUNTIME_DIR, got \(socket.path)"
            )
            XCTAssertTrue(socket.path.hasSuffix("openburnbar/daemon.sock"))
        } else {
            XCTAssertTrue(socket.path.contains("openburnbar"))
        }
    }

    func testSupportDirectoryIsLowercaseOpenburnbar() {
        let support = OpenBurnBarLinuxPaths.supportDirectoryURL()
        XCTAssertTrue(
            support.path.lowercased().contains("openburnbar"),
            "support path should use openburnbar segment: \(support.path)"
        )
        XCTAssertFalse(
            support.path.contains("OpenBurnBar"),
            "legacy PascalCase support dir must not be the default"
        )
    }

    func testHighValueSecretRefusePlaintextTrust() throws {
        let backend = LinuxInMemorySecretStoreBackend(
            backendName: "file",
            trustLevel: .explicitLowerTrustFile,
            secrets: ["database-key": "super-secret"]
        )
        let custodian = LinuxSecretCustodian(backends: [backend])
        XCTAssertThrowsError(
            try custodian.requireHighValueSecret(id: "database-key", secretClass: .databaseKey)
        ) { error in
            guard let secretError = error as? LinuxSecretStoreError else {
                return XCTFail("expected LinuxSecretStoreError")
            }
            if case .plaintextFallbackRefused = secretError {
                // expected
            } else {
                XCTFail("expected plaintextFallbackRefused, got \(secretError)")
            }
        }
    }

    func testSecretServiceTrustAcceptsHighValue() throws {
        let backend = LinuxInMemorySecretStoreBackend(
            trustLevel: .secretService,
            secrets: ["audit-signing-key": "signing-material"]
        )
        let custodian = LinuxSecretCustodian(backends: [backend])
        let record = try custodian.requireHighValueSecret(
            id: "audit-signing-key",
            secretClass: .auditSigningKey
        )
        XCTAssertEqual(record.secret, "signing-material")
        XCTAssertTrue(record.metadata.trustLevel.approvedForHighValueSecrets)
    }
}
#else
final class OpenBurnBarCoreLinuxEmptyTests: XCTestCase {
    func testLinuxPlaceholder() {}
}
#endif
