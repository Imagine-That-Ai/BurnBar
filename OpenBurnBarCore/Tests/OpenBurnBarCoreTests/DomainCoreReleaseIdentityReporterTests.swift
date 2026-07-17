import CryptoKit
import Foundation
import XCTest
#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif
@testable import OpenBurnBarCore

final class DomainCoreReleaseIdentityReporterTests: XCTestCase {
    // A canonical 40-char lowercase hex Git SHA used as the expected candidate
    // across the validation and identity tests. The actual loaded commit is
    // sourced from the native core at runtime, so the happy path derives the
    // expected value from the FFI rather than hard-coding it.
    private static let hex40 = String(repeating: "a", count: 40)

    private var tempDir: URL!
    private var executable: URL!
    private var report: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainCoreReleaseIdentityReporter.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        executable = tempDir.appendingPathComponent("host-executable")
        try? Data("placeholder-binary".utf8).write(to: executable)
        // Make it a regular file (already is), not a symlink.
        report = tempDir.appendingPathComponent("identity.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        executable = nil
        report = nil
        super.tearDown()
    }

    // MARK: - Static argument contract

    func test_argumentExposesStableCLIHook() {
        // The release process locates the reporter by this exact argument; a
        // rename would silently break the launchd/CLI wiring without a compile
        // error. Pin the literal.
        XCTAssertEqual(
            DomainCoreReleaseIdentityReporter.argument,
            "--domain-core-release-identity-report"
        )
    }

    // MARK: - candidate commit validation (runs without native core)

    func test_invalidCandidateCommitRejectsNonHexUppercaseAndWrongLength() {
        // Each row is a distinct boundary the regex `^[0-9a-f]{40}$` must reject.
        let cases: [(String, String)] = [
            ("", "empty"),
            (String(repeating: "a", count: 39), "39 chars — off by one below"),
            (String(repeating: "a", count: 41), "41 chars — off by one above"),
            ("A" + String(repeating: "b", count: 39), "uppercase hex rejected"),
            ("z" + String(repeating: "a", count: 39), "non-hex char rejected"),
            (String(repeating: "0", count: 40), "all-zero placeholder rejected")
        ]
        for (value, label) in cases {
            XCTAssertThrowsError(
                try DomainCoreReleaseIdentityReporter.write(
                    candidateCommit: value,
                    reportURL: report,
                    executableURL: executable
                ),
                "expected rejection for \(label)"
            ) { error in
                guard case DomainCoreReleaseIdentityError.invalidCandidateCommit = error else {
                    XCTFail("expected invalidCandidateCommit for \(label), got \(error)")
                    return
                }
            }
        }
    }

    func test_candidateCommitGateAcceptsExact40LowercaseHexRejectsTrailingLinebreaksAndWrongCase() {
        // Table-driven boundary contract for the candidate-commit gate. The
        // accepted row proves the gate lets exactly-40 lowercase hex through
        // (it reaches a downstream outcome — unavailableNativeCore without the
        // FFI, candidateCommitMismatch or success with it — but never
        // invalidCandidateCommit). The rejected rows pin the boundaries a
        // weakened validator (e.g. an end-of-line `$` that matches before a
        // trailing newline, or a length-only check that ignores case) would
        // let slip: every linebreak-terminated and wrong-case/wrong-length
        // variant must surface invalidCandidateCommit specifically.
        let hex40 = Self.hex40
        let accepted: [String] = [hex40]
        let rejected: [(String, String)] = [
            (hex40 + "\n", "trailing LF newline"),
            (hex40 + "\r", "trailing CR carriage return"),
            (hex40 + "\r\n", "trailing CRLF"),
            (hex40 + " ", "trailing space"),
            (" " + hex40, "leading space"),
            (String(repeating: "A", count: 40), "40 uppercase hex"),
            (String(repeating: "a", count: 39), "39 chars — short"),
            (String(repeating: "a", count: 41), "41 chars — long")
        ]

        for value in accepted {
            do {
                _ = try DomainCoreReleaseIdentityReporter.write(
                    candidateCommit: value,
                    reportURL: report,
                    executableURL: executable
                )
                // Success is valid: the candidate gate passed and (with the
                // FFI) the loaded commit happened to match.
            } catch DomainCoreReleaseIdentityError.invalidCandidateCommit {
                XCTFail("exact 40 lowercase hex must pass the candidate gate, but was rejected as invalidCandidateCommit")
            } catch {
                // unavailableNativeCore (no FFI) or candidateCommitMismatch
                // (FFI loaded commit differs) both prove the candidate gate
                // accepted the value; any non-invalidCandidateCommit throw
                // satisfies the accepted-row contract.
            }
        }

        for (value, label) in rejected {
            XCTAssertThrowsError(
                try DomainCoreReleaseIdentityReporter.write(
                    candidateCommit: value,
                    reportURL: report,
                    executableURL: executable
                ),
                "expected rejection for \(label)"
            ) { error in
                guard case DomainCoreReleaseIdentityError.invalidCandidateCommit = error else {
                    XCTFail("expected invalidCandidateCommit for \(label), got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - executable safety (runs without native core)

    func test_unsafeExecutableRejectsSymlink() throws {
        let link = tempDir.appendingPathComponent("exec-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path)

        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: Self.hex40,
                reportURL: report,
                executableURL: link
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.unsafeExecutable = error else {
                XCTFail("expected unsafeExecutable for symlink, got \(error)")
                return
            }
        }
    }

    func test_unsafeExecutableRejectsDirectory() throws {
        let dir = tempDir.appendingPathComponent("exec-dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: Self.hex40,
                reportURL: report,
                executableURL: dir
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.unsafeExecutable = error else {
                XCTFail("expected unsafeExecutable for directory, got \(error)")
                return
            }
        }
    }

    // MARK: - report path safety (runs without native core)

    func test_unsafeReportPathRejectsExistingFile() throws {
        // An existing report would be clobbered; the reporter requires an absent
        // path so a rerun cannot silently overwrite a prior identity artifact.
        try Data("stale".utf8).write(to: report)

        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: Self.hex40,
                reportURL: report,
                executableURL: executable
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.unsafeReportPath = error else {
                XCTFail("expected unsafeReportPath for existing file, got \(error)")
                return
            }
        }
    }

    func test_unsafeReportPathRejectsSymlink() throws {
        // Even though the destination doesn't exist yet, a symlink target that
        // resolves to an existing path is rejected because the writer would
        // follow it transparently.
        let real = tempDir.appendingPathComponent("real-target.json")
        try Data("x".utf8).write(to: real)
        let link = tempDir.appendingPathComponent("link-report.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: Self.hex40,
                reportURL: link,
                executableURL: executable
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.unsafeReportPath = error else {
                XCTFail("expected unsafeReportPath for symlink, got \(error)")
                return
            }
        }
    }

    // MARK: - native-core identity (requires the FFI; compile-skipped without it)

    #if canImport(OpenBurnBarDomainCoreFFI)
    func test_writeRejectsAllZerosPlaceholderArtifactCommit() throws {
        // The reporter must reject a native core whose candidate commit is the
        // all-zero placeholder — an uninitialized/placeholder artifact can never
        // pass the identity gate. This is the first FFI-side guard
        // and runs before the candidate-match check,
        // so it fires even when the caller-supplied commit is a
        // valid 40-hex SHA.
        let loadedCommit = OpenBurnBarDomainCoreFFI.domainCoreCandidateCommit()
        guard loadedCommit == String(repeating: "0", count: 40) else {
            // If the artifact carries a real commit, the all-zeros guard does
            // not fire; skip this case rather than mask a different behavior.
            throw XCTSkip("loaded artifact commit is not the all-zeros placeholder")
        }
        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: Self.hex40,
                reportURL: report,
                executableURL: executable
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.invalidLoadedCandidateCommit = error else {
                XCTFail("expected invalidLoadedCandidateCommit for all-zeros artifact, got \(error)")
                return
            }
        }
    }

    func test_writeRejectsCandidateCommitMismatchAgainstRealArtifact() throws {
        // Only reachable when the loaded artifact carries a real (non-zero)
        // candidate commit. When it does, a caller-supplied commit that differs
        // must be rejected with candidateCommitMismatch (not accepted or silently
        // echoed).
        let loadedCommit = OpenBurnBarDomainCoreFFI.domainCoreCandidateCommit()
        guard loadedCommit != String(repeating: "0", count: 40),
              loadedCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        else {
            throw XCTSkip("loaded artifact commit is the placeholder; mismatch path unreachable")
        }
        // Build a distinct-but-valid 40-hex SHA by flipping the last character.
        let last = loadedCommit.last
        let flipped = last == "a" ? "b" : "a"
        let mismatchedCommit = String(loadedCommit.dropLast()) + String(flipped)

        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: mismatchedCommit,
                reportURL: report,
                executableURL: executable
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.candidateCommitMismatch = error else {
                XCTFail("expected candidateCommitMismatch, got \(error)")
                return
            }
        }
    }

    func test_writeEmitsIdentityWhenArtifactCarriesRealCommit() throws {
        // The full happy-path identity contract: the reporter sources every
        // field from the loaded native core (not the argument), both
        // fingerprints are canonical 64-hex, the binary sha is the actual
        // SHA-256 of the executable, and the report file is newline-terminated
        // JSON that round-trips. Only reachable with a real (non-placeholder)
        // artifact; skipped when the checkout carries the all-zeros placeholder.
        let loadedCommit = OpenBurnBarDomainCoreFFI.domainCoreCandidateCommit()
        guard loadedCommit != String(repeating: "0", count: 40),
              loadedCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        else {
            throw XCTSkip("loaded artifact commit is the placeholder; happy path unreachable")
        }
        let sourceFingerprint = OpenBurnBarDomainCoreFFI.domainCoreSourceFingerprint()

        let identity = try DomainCoreReleaseIdentityReporter.write(
            candidateCommit: loadedCommit,
            reportURL: report,
            executableURL: executable
        )

        XCTAssertEqual(identity.candidateCommit, loadedCommit)
        XCTAssertEqual(identity.coreVersion, OpenBurnBarDomainCoreFFI.domainCoreVersion())
        XCTAssertEqual(identity.abiVersion, OpenBurnBarDomainCoreFFI.domainCoreAbiVersion())
        XCTAssertEqual(identity.sourceSha256, sourceFingerprint)

        XCTAssertMatches(identity.sourceSha256, #"^[0-9a-f]{64}$"#)
        XCTAssertMatches(identity.binarySha256, #"^[0-9a-f]{64}$"#)

        let expectedBinarySha = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(identity.binarySha256, expectedBinarySha)

        let written = try Data(contentsOf: report)
        XCTAssertEqual(written.last, 0x0A, "report must end with a newline byte")
        let jsonBody = written.dropLast()
        let decoded = try JSONDecoder().decode(DomainCoreReleaseIdentity.self, from: jsonBody)
        XCTAssertEqual(decoded, identity)
    }
    #else
    // Clean-checkout unavailable path: without the FFI, the reporter must fail
    // closed with unavailableNativeCore rather than silently emitting a stub.
    func test_writeFailsClosedWhenNativeCoreUnavailable() {
        XCTAssertThrowsError(
            try DomainCoreReleaseIdentityReporter.write(
                candidateCommit: Self.hex40,
                reportURL: report,
                executableURL: executable
            )
        ) { error in
            guard case DomainCoreReleaseIdentityError.unavailableNativeCore = error else {
                XCTFail("expected unavailableNativeCore without FFI, got \(error)")
                return
            }
        }
    }
    #endif
}

// MARK: - Regex match helper (XCTest has no built-in NSRegularExpression match assert)

private func XCTAssertMatches(
    _ string: String,
    _ pattern: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let range = NSRange(string.startIndex..., in: string)
    let regex = try? NSRegularExpression(pattern: pattern, options: [])
    let matched = regex?.firstMatch(in: string, options: [], range: range) != nil
    XCTAssertTrue(matched, "expected \(string) to match \(pattern)", file: file, line: line)
}
