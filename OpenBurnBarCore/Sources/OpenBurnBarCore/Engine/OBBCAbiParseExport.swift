// SPDX-License-Identifier: AGPL-3.0-only
//
// Windows-port WPD-0007: minimal in-process Engine C-ABI surface (proof-of-concept).
// `obb_parse_cli_stdout` runs the real lifted log parser over CLI stream-json bytes
// (same path as ConPTY → parse in the B0 spike), returning portable TokenUsage JSON.
//
// Full engine binding is a follow-up; this exports ONE parse entry point for P/Invoke.

import Foundation

// MARK: - Portable contract (matches docs/windows-port/PARSER_OUTPUT_CONTRACT.md)

public struct OBBCAbiParserUsageRecord: Codable, Equatable, Sendable {
    public let provider: String
    public let sessionId: String
    public let projectName: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let costNanoUSD: Int
    public let usageSource: String
    public let provenanceMethod: String
    public let provenanceConfidence: String
    public let estimatorVersion: String

    init(_ usage: TokenUsage) {
        provider = usage.provider.rawValue
        sessionId = usage.sessionId
        projectName = usage.projectName
        model = usage.model
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheCreationTokens = usage.cacheCreationTokens
        cacheReadTokens = usage.cacheReadTokens
        reasoningTokens = usage.reasoningTokens
        totalTokens = usage.totalTokens
        costNanoUSD = OBBCAbiContract.nanoUSD(usage.costUSD)
        usageSource = usage.usageSource.rawValue
        provenanceMethod = usage.provenanceMethod.rawValue
        provenanceConfidence = usage.provenanceConfidence.rawValue
        estimatorVersion = usage.estimatorVersion
    }
}

public struct OBBCAbiParseCliStdoutResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public let usages: [OBBCAbiParserUsageRecord]

    static func success(_ usages: [TokenUsage]) -> OBBCAbiParseCliStdoutResponse {
        let records = OBBCAbiContract.sortedUsages(usages.map(OBBCAbiParserUsageRecord.init))
        return OBBCAbiParseCliStdoutResponse(ok: true, error: nil, usages: records)
    }

    static func failure(_ message: String) -> OBBCAbiParseCliStdoutResponse {
        OBBCAbiParseCliStdoutResponse(ok: false, error: message, usages: [])
    }
}

enum OBBCAbiContract {
    static func nanoUSD(_ usd: Double) -> Int {
        guard usd.isFinite else { return 0 }
        let scaled = (usd * 1_000_000_000).rounded(.toNearestOrAwayFromZero)
        if scaled >= Double(Int.max) { return Int.max }
        if scaled <= Double(Int.min) { return Int.min }
        return Int(scaled)
    }

    static func sortedUsages(_ records: [OBBCAbiParserUsageRecord]) -> [OBBCAbiParserUsageRecord] {
        records.sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
            if lhs.projectName != rhs.projectName { return lhs.projectName < rhs.projectName }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            if lhs.inputTokens != rhs.inputTokens { return lhs.inputTokens < rhs.inputTokens }
            if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens < rhs.outputTokens }
            if lhs.cacheCreationTokens != rhs.cacheCreationTokens {
                return lhs.cacheCreationTokens < rhs.cacheCreationTokens
            }
            if lhs.cacheReadTokens != rhs.cacheReadTokens { return lhs.cacheReadTokens < rhs.cacheReadTokens }
            if lhs.reasoningTokens != rhs.reasoningTokens { return lhs.reasoningTokens < rhs.reasoningTokens }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens < rhs.totalTokens }
            if lhs.costNanoUSD != rhs.costNanoUSD { return lhs.costNanoUSD < rhs.costNanoUSD }
            if lhs.usageSource != rhs.usageSource { return lhs.usageSource < rhs.usageSource }
            if lhs.provenanceMethod != rhs.provenanceMethod { return lhs.provenanceMethod < rhs.provenanceMethod }
            if lhs.provenanceConfidence != rhs.provenanceConfidence {
                return lhs.provenanceConfidence < rhs.provenanceConfidence
            }
            return lhs.estimatorVersion < rhs.estimatorVersion
        }
    }

    static func encodeResponse(_ response: OBBCAbiParseCliStdoutResponse) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum OBBCAbiClaudeStdoutParser {
    /// Same encoded project dir as the G2 / ParserContract corpus.
    static let projectDir = "-Users-test-Documents-ParserContract"
    static let sessionId = "claude-basic-session"

    static func parse(stdout: String, provider: AgentProvider) async throws -> [TokenUsage] {
        guard provider == .claudeCode else {
            throw OBBCAbiParseError.unsupportedProvider(provider.rawValue)
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("obb-abi-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let projectsRoot = root.appendingPathComponent(".claude/projects", isDirectory: true)
        let projectPath = projectsRoot.appendingPathComponent(projectDir, isDirectory: true)
        try fm.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let sessionFile = projectPath.appendingPathComponent("\(sessionId).jsonl")
        try stdout.write(to: sessionFile, atomically: true, encoding: .utf8)

        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true))
        let parser = ClaudeCodeParser(
            fileManager: fm,
            appPaths: appPaths,
            projectsDirectoryOverride: projectsRoot
        )
        let result = try await parser.parse()
        return result.usages
    }
}

enum OBBCAbiParseError: Error, CustomStringConvertible {
    case invalidUTF8
    case missingArgument(String)
    case unknownProvider(String)
    case unsupportedProvider(String)
    case encodeFailed

    var description: String {
        switch self {
        case .invalidUTF8: return "invalid UTF-8 in C string argument"
        case .missingArgument(let name): return "missing required argument: \(name)"
        case .unknownProvider(let token): return "unknown provider: \(token)"
        case .unsupportedProvider(let token): return "provider not supported for cli stdout parse: \(token)"
        case .encodeFailed: return "failed to encode JSON response"
        }
    }
}

@_cdecl("obb_parse_cli_stdout")
public func obb_parse_cli_stdout(
    stdout: UnsafePointer<CChar>?,
    provider: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let response: OBBCAbiParseCliStdoutResponse
    do {
        response = try OBBCAbiParseExport.run(stdout: stdout, provider: provider)
    } catch let error as OBBCAbiParseError {
        response = .failure(error.description)
    } catch {
        response = .failure(String(describing: error))
    }

    guard let json = OBBCAbiContract.encodeResponse(response),
          let ptr = OBBCAbiMemory.duplicateCString(json) else {
        let fallback = #"{"error":"encode_failed","ok":false,"usages":[]}"#
        return OBBCAbiMemory.duplicateCString(fallback)
    }
    return ptr
}

enum OBBCAbiParseExport {
    static func run(
        stdout: UnsafePointer<CChar>?,
        provider: UnsafePointer<CChar>?
    ) throws -> OBBCAbiParseCliStdoutResponse {
        guard let stdout else { throw OBBCAbiParseError.missingArgument("stdout") }
        guard let providerPtr = provider else { throw OBBCAbiParseError.missingArgument("provider") }

        let stdoutString = String(cString: stdout)
        let providerToken = String(cString: providerPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerToken.isEmpty else { throw OBBCAbiParseError.missingArgument("provider") }

        guard let agentProvider = AgentProvider(rawValue: providerToken) else {
            throw OBBCAbiParseError.unknownProvider(providerToken)
        }

        let usages = try awaitBlocking {
            try await OBBCAbiClaudeStdoutParser.parse(stdout: stdoutString, provider: agentProvider)
        }
        return .success(usages)
    }

    /// Bridge async parser into the synchronous C ABI (export blocks until parse completes).
    private static func awaitBlocking<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) throws -> T {
        let holder = OBBCAbiBlockingOutcome<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                holder.store(.success(try await operation()))
            } catch {
                holder.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try holder.take()
    }
}

// NSLock-protected blocking outcome result; safe for concurrent access.
// sendable-allowlist: nslock-blocking-outcome
private final class OBBCAbiBlockingOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        outcome = value
    }

    func take() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw OBBCAbiParseError.encodeFailed
        }
    }
}
