import Foundation

/// Offline OpenTimestamps verification via the official `ots` CLI when installed.
public struct ComputerUseOpenTimestampsProofVerifier: Sendable {
    public init() {}

    public enum Status: String, Sendable, Equatable {
        case verified
        case verifyFailed
        case verifierUnavailable
        case proofMissing
    }

    public struct Result: Sendable, Equatable {
        public let status: Status
        public let output: String

        public var isVerified: Bool { status == .verified }
    }

    /// Verify `chain.jsonl.ots` beside `chain.jsonl` using `ots verify`.
    public func verify(proofAt proofURL: URL, fileManager: FileManager = .default) -> Result {
        guard fileManager.fileExists(atPath: proofURL.path) else {
            return Result(status: .proofMissing, output: "proof file missing: \(proofURL.path)")
        }
        guard let otsPath = locateOTSBinary() else {
            return Result(status: .verifierUnavailable, output: "ots CLI not found on PATH")
        }
        let workingDirectory = proofURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: otsPath)
        process.arguments = ["verify", proofURL.lastPathComponent]
        process.currentDirectoryURL = workingDirectory
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 {
                return Result(status: .verified, output: text.isEmpty ? "ots verify exited 0" : text)
            }
            return Result(
                status: .verifyFailed,
                output: text.isEmpty ? "ots verify failed with status \(process.terminationStatus)" : text
            )
        } catch {
            return Result(status: .verifierUnavailable, output: error.localizedDescription)
        }
    }

    private func locateOTSBinary() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ots"]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
