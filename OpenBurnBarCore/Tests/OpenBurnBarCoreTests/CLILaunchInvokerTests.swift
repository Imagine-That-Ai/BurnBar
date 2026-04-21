import XCTest
@testable import OpenBurnBarCore

final class CLILaunchInvokerTests: XCTestCase {
    override func tearDown() {
        CLILaunchInvoker.launchHandler = nil
        CLILaunchInvoker.startupObservationTimeout = 1.5
        super.tearDown()
    }

    func test_classifyQuotaExhaustion_matchesExplicitQuotaSignals() {
        let output = "Error: quota exhausted for the 5-hour window."
        let detail = CLILaunchInvoker.classifyQuotaExhaustion(for: .codex, in: output)
        XCTAssertEqual(detail, output)
    }

    func test_launchCLI_detectsQuotaExhaustionFromStartupOutput() async throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-quota-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        echo "quota exhausted for the 5-hour window" >&2
        sleep 2
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        CLILaunchInvoker.startupObservationTimeout = 1.0

        let result = await CLILaunchInvoker.launchCLI(
            cliType: .codex,
            executable: executable
        )

        switch result {
        case .success:
            XCTFail("Expected quota exhaustion to fail the launch")
        case .failure(let error):
            guard case .quotaExhausted(let detail) = error else {
                return XCTFail("Expected .quotaExhausted, got \(error)")
            }
            XCTAssertTrue(detail.localizedCaseInsensitiveContains("quota exhausted"))
        }
    }

    func test_launchCLI_detectsQuotaExhaustionFromStartupOutputAcrossRepeatedLaunches() async throws {
        CLILaunchInvoker.startupObservationTimeout = 1.0

        for _ in 0..<6 {
            let executable = FileManager.default.temporaryDirectory
                .appendingPathComponent("cli-quota-repeat-\(UUID().uuidString)")
            let script = """
            #!/bin/sh
            echo "quota exhausted for the 5-hour window" >&2
            sleep 2
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            defer { try? FileManager.default.removeItem(at: executable) }

            let result = await CLILaunchInvoker.launchCLI(
                cliType: .codex,
                executable: executable
            )

            switch result {
            case .success:
                XCTFail("Expected quota exhaustion to fail the launch")
            case .failure(let error):
                guard case .quotaExhausted(let detail) = error else {
                    return XCTFail("Expected .quotaExhausted, got \(error)")
                }
                XCTAssertTrue(detail.localizedCaseInsensitiveContains("quota exhausted"))
            }
        }
    }

    func test_launchCLI_succeedsAfterObservationWindowForHealthyProcess() async throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-healthy-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        sleep 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        CLILaunchInvoker.startupObservationTimeout = 0.1

        let result = await CLILaunchInvoker.launchCLI(
            cliType: .claude,
            executable: executable
        )

        switch result {
        case .success:
            XCTAssertTrue(true)
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }
}
