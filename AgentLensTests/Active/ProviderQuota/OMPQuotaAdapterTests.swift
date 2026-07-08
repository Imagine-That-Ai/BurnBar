import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class OMPQuotaAdapterTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var pathBinURL: URL!
    private var fakeOmpURL: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        CLIExecutableResolver.clearCache()
        fileManager = FileManager.default
        tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pathBinURL = tempDirectoryURL.appendingPathComponent("bin", isDirectory: true)
        fakeOmpURL = pathBinURL.appendingPathComponent("omp")
        try? fileManager.createDirectory(at: pathBinURL, withIntermediateDirectories: true)
        let resolvedFakeOmpURL = fakeOmpURL!
        CLILaunchAdapter.executableResolver = { cliType in
            guard cliType == .omp,
                  FileManager.default.isExecutableFile(atPath: resolvedFakeOmpURL.path) else {
                return nil
            }
            return resolvedFakeOmpURL
        }
    }

    override func tearDown() {
        CLIExecutableResolver.clearCache()
        CLILaunchAdapter.executableResolver = nil
        try? fileManager.removeItem(at: tempDirectoryURL)
        super.tearDown()
    }

    func testFetch_whenOmpNotOnPath_returnsUnavailableWithoutThrowing() async throws {
        let adapter = OMPQuotaAdapter()
        let isolatedPath = "/openburnbar-nonexistent-bin:\(UUID().uuidString)"
        let context = try makeContext(path: isolatedPath)
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.omp.rawValue)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.source, ProviderQuotaSourceKind.unavailable.rawValue)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("OMP CLI was not found"), true)
    }

    func testFetch_parsesUsageJSONFromFakeOmpExecutable() async throws {
        let usageJSON = """
        {
          "generatedAt": 1750000000000,
          "reports": [
            {
              "provider": "openai-codex",
              "limits": [
                {
                  "id": "codex-5h",
                  "label": "5h window",
                  "window": { "id": "5h", "durationMs": 18000000, "resetsAt": 1750001800000 },
                  "amount": {
                    "used": 12,
                    "limit": 100,
                    "remaining": 88,
                    "usedFraction": 0.12,
                    "unit": "requests"
                  }
                }
              ]
            }
          ]
        }
        """
        try installFakeOmp(emittingJSON: usageJSON)
        let adapter = OMPQuotaAdapter()

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.omp.rawValue)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.source, ProviderQuotaSourceKind.localCLI.rawValue)
        XCTAssertEqual(snapshot.buckets.count, 1)
        let bucket = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(bucket.key, "omp-openai-codex-codex-5h")
        XCTAssertEqual(bucket.label, "Codex · 5h window")
        XCTAssertEqual(bucket.usedValue, 12)
        XCTAssertEqual(bucket.limitValue, 100)
        XCTAssertEqual(bucket.remainingValue, 88)
        XCTAssertEqual(bucket.unit, .requests)
        XCTAssertEqual(bucket.windowKind, .rollingHours)
        XCTAssertEqual(try XCTUnwrap(bucket.usedPercent), 12, accuracy: 0.01)
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, 1_750_000_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bucket.resetsAt).timeIntervalSince1970, 1_750_001_800, accuracy: 0.001)
    }

    func testFetch_whenFakeOmpExitsNonZero_returnsUnavailableWithProcessDetail() async throws {
        try installFakeOmp(exitCode: 3, stderr: "usage unavailable")
        let adapter = OMPQuotaAdapter()

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.omp.rawValue)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("omp usage"), true)
        XCTAssertEqual(snapshot.statusMessage?.contains("usage unavailable"), true)
    }

    func testFetch_whenUsagePayloadHasNoBuckets_returnsUnavailableStatus() async throws {
        try installFakeOmp(emittingJSON: #"{"generatedAt":1750000000000,"reports":[]}"#)
        let adapter = OMPQuotaAdapter()

        let context = try makeContext()
        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.omp.rawValue)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("no displayable usage limits"), true)
    }

    func testFetch_invokesOmpUsageWithJsonAndRedactFlags() async throws {
        let markerURL = tempDirectoryURL.appendingPathComponent("omp-usage-invocation.txt")
        try installFakeOmp(recordingInvocationTo: markerURL)
        let adapter = OMPQuotaAdapter()

        let context = try makeContext()
        _ = try await adapter.fetch(context: context)

        let invocation = try String(contentsOf: markerURL, encoding: .utf8)
        XCTAssertEqual(invocation, "usage --json --redact")
    }

    private func installFakeOmp(emittingJSON json: String) throws {
        let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        let script = """
        #!/bin/sh
        if [ "$1" = "usage" ] && [ "$2" = "--json" ] && [ "$3" = "--redact" ]; then
          printf '%s' "\(escaped)"
          exit 0
        fi
        echo "unexpected argv: $*" 1>&2
        exit 2
        """
        try Data(script.utf8).write(to: fakeOmpURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOmpURL.path)
    }

    private func installFakeOmp(exitCode: Int, stderr: String) throws {
        let script = """
        #!/bin/sh
        echo "\(stderr)" 1>&2
        exit \(exitCode)
        """
        try Data(script.utf8).write(to: fakeOmpURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOmpURL.path)
    }

    private func installFakeOmp(recordingInvocationTo markerURL: URL) throws {
        let script = """
        #!/bin/sh
        printf '%s' "$1 $2 $3" > "\(markerURL.path)"
        printf '{"generatedAt":1750000000000,"reports":[]}'
        exit 0
        """
        try Data(script.utf8).write(to: fakeOmpURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOmpURL.path)
    }

    private func makeContext(path: String? = nil) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: tempDirectoryURL)
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let pathValue = path ?? pathBinURL.path
        let environment = [
            "PATH": pathValue,
            "HOME": tempDirectoryURL.path,
            "SHELL": "/bin/sh"
        ]

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: URLSession(configuration: .ephemeral),
            environment: environment,
            homeDirectoryURL: tempDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: ClaudeQuotaBridgeManager(
                appPaths: appPaths,
                homeDirectoryURL: tempDirectoryURL,
                fileManager: fileManager,
                snapshotStore: snapshotStore
            ),
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: [:],
            cliExecutor: ProcessBackedCLIExecutor()
        )
    }

}

private struct ProcessBackedCLIExecutor: CLIExecutor {
    func run(executable: String, arguments: [String], environment: [String: String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return outputData
        }

        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData, encoding: .utf8) ?? "process exited \(process.terminationStatus)"
        throw NSError(domain: "OMPQuotaAdapterTests", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
    }
}
