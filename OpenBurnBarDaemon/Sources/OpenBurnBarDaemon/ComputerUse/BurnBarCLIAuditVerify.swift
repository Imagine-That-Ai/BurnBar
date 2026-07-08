import Foundation
import OpenBurnBarComputerUseCore

enum BurnBarCLIAuditVerify {
    static func run(arguments: [String]) throws -> BurnBarCLIInvocationResult {
        if arguments.first == "--archive" {
            return try runArchiveVerify(arguments: Array(arguments.dropFirst()))
        }

        guard let sessionDirectory = arguments.first else {
            throw BurnBarCLIError.missingArgument(Self.usageText)
        }
        var maxEntryIndex: Int?
        var skipOTS = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--max-entry-index":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw BurnBarCLIError.missingArgument("--max-entry-index requires an integer")
                }
                maxEntryIndex = value
            case "--skip-opentimestamps":
                skipOTS = true
            default:
                throw BurnBarCLIError.invalidCommand("audit-verify \(arguments[index])")
            }
            index += 1
        }

        let directoryURL = URL(fileURLWithPath: sessionDirectory, isDirectory: true)
        let report = try ComputerUseAuditVerifier().verifySessionDirectory(
            directoryURL,
            maxEntryIndexInclusive: maxEntryIndex,
            verifyOpenTimestamps: !skipOTS
        )
        let lines = format(report: report, maxEntryIndex: maxEntryIndex)
        return BurnBarCLIInvocationResult(
            output: lines.joined(separator: "\n"),
            exitCode: report.isFullyVerified ? EXIT_SUCCESS : EXIT_FAILURE
        )
    }

    private static func runArchiveVerify(arguments: [String]) throws -> BurnBarCLIInvocationResult {
        guard let archivePath = arguments.first else {
            throw BurnBarCLIError.missingArgument(Self.usageText)
        }
        var signaturePath: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--signature":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarCLIError.missingArgument("--signature requires a path")
                }
                signaturePath = arguments[index]
            default:
                throw BurnBarCLIError.invalidCommand("audit-verify --archive \(arguments[index])")
            }
            index += 1
        }

        let archiveURL = URL(fileURLWithPath: archivePath)
        let signatureURL = signaturePath.map { URL(fileURLWithPath: $0) }
        do {
            let entries = try ComputerUseAuditExportWriter().verify(
                archive: archiveURL,
                signatureURL: signatureURL
            )
            let paths = entries.map(\.path).sorted()
            return BurnBarCLIInvocationResult(
                output: [
                    "archive_valid=true",
                    "entry_count=\(entries.count)",
                    "contains_manifest=\(paths.contains("manifest.json"))",
                    "contains_chain=\(paths.contains("chain.jsonl"))",
                    "contains_signed_head=\(paths.contains(ComputerUseAuditHeadFinalizer.signedHeadFilename))",
                    "signature_checked=\(signatureURL != nil)",
                    "fully_verified=true"
                ].joined(separator: "\n"),
                exitCode: EXIT_SUCCESS
            )
        } catch {
            return BurnBarCLIInvocationResult(
                output: [
                    "archive_valid=false",
                    "first_invalid_reason=\(error.localizedDescription)",
                    "fully_verified=false"
                ].joined(separator: "\n"),
                exitCode: EXIT_FAILURE
            )
        }
    }

    static let usageText = """
    Usage:
      openburnbar-cli audit-verify <session-directory> [--max-entry-index N] [--skip-opentimestamps]
      openburnbar-cli audit-verify --archive <archive.tar.gz> [--signature <archive.sig.json>]
    """

    private static func format(report: ComputerUseAuditVerifier.VerificationReport, maxEntryIndex: Int?) -> [String] {
        var lines: [String] = []
        lines.append("chain_valid=\(report.chainValid)")
        lines.append("entry_count=\(report.entryCount)")
        if let head = report.headHashHex {
            lines.append("head_hash_hex=\(head)")
        }
        if let headSignatureValid = report.headSignatureValid {
            lines.append("head_signature_valid=\(headSignatureValid)")
        }
        if let maxEntryIndex {
            lines.append("max_entry_index_inclusive=\(maxEntryIndex)")
            lines.append("no_entries_after_index=\(report.noEntriesAfterIndex ?? false)")
        }
        if let openTimestampsVerified = report.openTimestampsVerified {
            lines.append("opentimestamps_verified=\(openTimestampsVerified)")
        }
        if let detail = report.openTimestampsDetail, !detail.isEmpty {
            lines.append("opentimestamps_detail=\(detail)")
        }
        if let reason = report.firstInvalidReason {
            lines.append("first_invalid_reason=\(reason.rawValue)")
        }
        lines.append("fully_verified=\(report.isFullyVerified)")
        return lines
    }
}
