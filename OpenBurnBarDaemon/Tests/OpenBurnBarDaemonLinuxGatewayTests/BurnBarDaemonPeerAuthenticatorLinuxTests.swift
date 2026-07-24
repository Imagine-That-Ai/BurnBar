#if os(Linux)
import Glibc
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonPeerAuthenticatorLinuxTests: XCTestCase {
    func testLinuxPeerCredentialReadsKernelExecutableLink() throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = Glibc.close(descriptors[0])
            _ = Glibc.close(descriptors[1])
        }

        let credential = try BurnBarDaemonPeerAuthenticator.linuxPeerCredential(
            socketFD: descriptors[0]
        )
        XCTAssertFalse(credential.executablePath.isEmpty)
        XCTAssertEqual(credential.executableSHA256.count, 64)
    }
}
#endif
