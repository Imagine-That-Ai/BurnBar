import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Focused coverage for the RR-3 install/launch-path staleness probe in
/// `OpenBurnBarDaemonManager+Lifecycle.swift`.
///
/// `installedDaemonBinaryNeedsRefresh` decides whether the user-writable
/// installed daemon binary must be re-installed (which re-runs signature
/// validation + atomic copy). The size/mtime fast-path used to swallow
/// `attributesOfItem` failures with `try?`, silently dropping the evidence it
/// needs to make that security decision. The fix FAILS CLOSED: when the probe
/// cannot stat either binary it forces a refresh rather than leaving a
/// possibly-swapped installed binary in place.
final class OpenBurnBarDaemonManagerLifecycleMattersTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let rootURL: URL
        let sourceURL: URL
        let installedURL: URL
        let paths: OpenBurnBarDaemonRuntimePaths

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeHarness(name: String) throws -> Harness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OBBDaemonLifecycleMatters-\(name)-\(UUID().uuidString)", isDirectory: true)
        let supportDirectory = rootURL.appendingPathComponent("support", isDirectory: true)
        let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)

        let sourceURL = rootURL.appendingPathComponent("source-openburnbar-daemon", isDirectory: false)
        let installedURL = daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)

        let paths = OpenBurnBarDaemonRuntimePaths(
            supportDirectory: supportDirectory,
            daemonDirectory: daemonDirectory,
            frameworksDirectory: supportDirectory.appendingPathComponent("Frameworks", isDirectory: true),
            installedBinaryURL: installedURL,
            socketURL: supportDirectory.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: rootURL.appendingPathComponent(
                "Library/LaunchAgents/com.openburnbar.daemon.plist",
                isDirectory: false
            )
        )
        return Harness(rootURL: rootURL, sourceURL: sourceURL, installedURL: installedURL, paths: paths)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func dependencies(
        fileManager: FileManager,
        resolveDaemonBinary: @escaping @Sendable () -> URL?
    ) -> OpenBurnBarDaemonDependencies {
        OpenBurnBarDaemonDependencies(
            fileManager: fileManager,
            runProcess: { _, _ in "" },
            resolveDaemonBinary: resolveDaemonBinary,
            requestHealth: { _ in
                BurnBarHealthResponse(
                    ok: true,
                    daemonVersion: "test-daemon",
                    protocolVersion: BurnBarProtocolVersion.current,
                    socketPath: "/tmp/openburnbar-lifecycle-matters-test.sock"
                )
            },
            requestConfig: { _ in BurnBarProviderConfigurationSnapshot(providers: []) },
            updateConfig: { _, snapshot in snapshot },
            requestRecentUsage: { _, _ in [] },
            requestControllerProjects: { _ in [] },
            upsertControllerProject: { _, project in project },
            recordControllerReviewRun: { _, run in
                BurnBarControllerReviewRunRecordResponse(
                    run: run,
                    summary: BurnBarControllerSummary(
                        updatedAt: Date(),
                        counts: BurnBarControllerCounts(
                            projectCount: 0,
                            pendingQuestionCount: 0,
                            openFollowupCount: 0,
                            activeMissionCount: 0,
                            staleProjectCount: 0
                        ),
                        freshness: .missing
                    )
                )
            }
        )
    }

    /// A `FileManager` whose `attributesOfItem` faults for a configured path,
    /// modelling a stat race / unmount / ACL denial that strikes after the
    /// existence + executability probes have already passed. Every other call
    /// forwards to the real file system.
    private final class AttributeFaultingFileManager: FileManager, @unchecked Sendable {
        struct StatDenied: Error {}
        let faultingPath: String
        private(set) var faultedReads = 0

        init(faultingPath: String) {
            self.faultingPath = faultingPath
            super.init()
        }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            if path == faultingPath {
                faultedReads += 1
                throw StatDenied()
            }
            return try super.attributesOfItem(atPath: path)
        }
    }

    // MARK: - Fail-closed: blind probe forces a refresh

    func test_needsRefresh_failsClosedWhenInstalledBinaryAttributesAreUnreadable() throws {
        let harness = try makeHarness(name: "installed-stat-denied")
        defer { harness.cleanup() }

        // Source and installed binaries are byte-identical with matching mtime,
        // so the size/mtime/digest path would otherwise report "no refresh".
        try writeExecutable("#!/bin/sh\nexit 0\n", to: harness.sourceURL)
        try FileManager.default.copyItem(at: harness.sourceURL, to: harness.installedURL)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: harness.sourceURL.path)
        if let modifiedAt = sourceAttributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: harness.installedURL.path
            )
        }

        // Sanity: with a real FileManager this pair reports "no refresh".
        let cleanDeps = dependencies(
            fileManager: .default,
            resolveDaemonBinary: { harness.sourceURL }
        )
        XCTAssertFalse(
            OpenBurnBarDaemonManager.installedDaemonBinaryNeedsRefresh(
                paths: harness.paths,
                dependencies: cleanDeps
            ),
            "Identical binaries with matching mtime must not trigger a refresh on a healthy file system."
        )

        // Now make stat() of the installed binary fault. The probe is blind to
        // staleness and must FAIL CLOSED by forcing a refresh.
        let faultingFileManager = AttributeFaultingFileManager(faultingPath: harness.installedURL.path)
        let faultingDeps = dependencies(
            fileManager: faultingFileManager,
            resolveDaemonBinary: { harness.sourceURL }
        )

        XCTAssertTrue(
            OpenBurnBarDaemonManager.installedDaemonBinaryNeedsRefresh(
                paths: harness.paths,
                dependencies: faultingDeps
            ),
            "An unreadable installed-binary stat must fail closed (force refresh), not silently keep the on-disk binary."
        )
        XCTAssertGreaterThan(
            faultingFileManager.faultedReads,
            0,
            "The probe must actually attempt to read the installed-binary attributes."
        )
    }

    func test_needsRefresh_failsClosedWhenSourceBinaryAttributesAreUnreadable() throws {
        let harness = try makeHarness(name: "source-stat-denied")
        defer { harness.cleanup() }

        try writeExecutable("#!/bin/sh\nexit 0\n", to: harness.sourceURL)
        try FileManager.default.copyItem(at: harness.sourceURL, to: harness.installedURL)

        let faultingFileManager = AttributeFaultingFileManager(faultingPath: harness.sourceURL.path)
        let faultingDeps = dependencies(
            fileManager: faultingFileManager,
            resolveDaemonBinary: { harness.sourceURL }
        )

        XCTAssertTrue(
            OpenBurnBarDaemonManager.installedDaemonBinaryNeedsRefresh(
                paths: harness.paths,
                dependencies: faultingDeps
            ),
            "An unreadable source-binary stat must fail closed (force refresh)."
        )
        XCTAssertGreaterThan(faultingFileManager.faultedReads, 0)
    }

    // MARK: - Positive controls: readable attributes preserve the real decision

    func test_needsRefresh_detectsStaleInstalledBinaryWhenAttributesAreReadable() throws {
        let harness = try makeHarness(name: "stale-detect")
        defer { harness.cleanup() }

        // Differing content => differing size => refresh, with a healthy FS.
        try writeExecutable("#!/bin/sh\nexit 0\necho fresh\n", to: harness.sourceURL)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: harness.installedURL)

        let deps = dependencies(
            fileManager: .default,
            resolveDaemonBinary: { harness.sourceURL }
        )

        XCTAssertTrue(
            OpenBurnBarDaemonManager.installedDaemonBinaryNeedsRefresh(
                paths: harness.paths,
                dependencies: deps
            ),
            "A size mismatch on a healthy file system must still report a needed refresh."
        )
    }
}
