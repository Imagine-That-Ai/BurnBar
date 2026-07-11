// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import OpenBurnBarKernel

/// Paths supplied by the Windows host. Keeping discovery outside the parser engine
/// lets packaged, portable, and test hosts use the same parser implementation.
public struct OBBCAbiUsageScanRequest: Codable, Equatable, Sendable {
    public let supportDirectory: String
    public let homeDirectory: String
    public let claudeProjectsDirectory: String
    public let codexHomeDirectory: String
    public let cursorSessionsDirectory: String
    public let factorySessionsDirectory: String
    public let hermesHomeDirectory: String
    public let includeConversationBodies: Bool

    public init(
        supportDirectory: String,
        homeDirectory: String,
        claudeProjectsDirectory: String,
        codexHomeDirectory: String,
        cursorSessionsDirectory: String,
        factorySessionsDirectory: String,
        hermesHomeDirectory: String,
        includeConversationBodies: Bool = true
    ) {
        self.supportDirectory = supportDirectory
        self.homeDirectory = homeDirectory
        self.claudeProjectsDirectory = claudeProjectsDirectory
        self.codexHomeDirectory = codexHomeDirectory
        self.cursorSessionsDirectory = cursorSessionsDirectory
        self.factorySessionsDirectory = factorySessionsDirectory
        self.hermesHomeDirectory = hermesHomeDirectory
        self.includeConversationBodies = includeConversationBodies
    }
}

public enum OBBCAbiProviderScanStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case missing
    case failed
}

public struct OBBCAbiProviderScanResult: Codable, Equatable, Sendable {
    public let provider: String
    public let status: OBBCAbiProviderScanStatus
    public let usageCount: Int
    public let conversationCount: Int
    public let error: String?
}

/// Full-fidelity local usage row for the Windows runtime. This is intentionally
/// separate from the timestamp-free parser golden contract.
public struct OBBCAbiRuntimeUsageRecord: Codable, Equatable, Sendable {
    public let id: String
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
    public let startUnixMilliseconds: Int64
    public let endUnixMilliseconds: Int64
    public let createdUnixMilliseconds: Int64
    public let usageSource: String
    public let providerID: String
    public let providerAccountID: String?
    public let providerAccountLabel: String?
    public let providerAccountSource: String?
    public let provenanceMethod: String
    public let provenanceConfidence: String
    public let estimatorVersion: String
    public let parentRequestID: String?

    init(_ usage: TokenUsage) {
        id = usage.id.uuidString.lowercased()
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
        startUnixMilliseconds = Self.milliseconds(usage.startTime)
        endUnixMilliseconds = Self.milliseconds(usage.endTime)
        createdUnixMilliseconds = Self.milliseconds(usage.createdAt)
        usageSource = usage.usageSource.rawValue
        providerID = usage.providerID.rawValue
        providerAccountID = usage.providerAccountID
        providerAccountLabel = usage.providerAccountLabel
        providerAccountSource = usage.providerAccountSource?.rawValue
        provenanceMethod = usage.provenanceMethod.rawValue
        provenanceConfidence = usage.provenanceConfidence.rawValue
        estimatorVersion = usage.estimatorVersion
        parentRequestID = usage.parentRequestID
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

public struct OBBCAbiRuntimeConversationRecord: Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let sessionId: String
    public let projectName: String
    public let inferredTaskTitle: String
    public let fullText: String
    public let indexedUnixMilliseconds: Int64
    public let messageCount: Int
    public let workingDirectory: String?

    init(_ conversation: ConversationRecord) {
        id = conversation.id
        provider = conversation.provider.rawValue
        sessionId = conversation.sessionId
        projectName = conversation.projectName
        inferredTaskTitle = conversation.inferredTaskTitle
        fullText = conversation.fullText
        indexedUnixMilliseconds = Int64((conversation.indexedAt.timeIntervalSince1970 * 1_000).rounded())
        messageCount = conversation.messageCount
        workingDirectory = conversation.workingDirectory
    }
}

public struct OBBCAbiUsageScanResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public let providers: [OBBCAbiProviderScanResult]
    public let usages: [OBBCAbiRuntimeUsageRecord]
    public let conversations: [OBBCAbiRuntimeConversationRecord]

    static func failure(_ error: String) -> OBBCAbiUsageScanResponse {
        OBBCAbiUsageScanResponse(ok: false, error: error, providers: [], usages: [], conversations: [])
    }
}

private struct OBBCAbiProviderOutput: Sendable {
    let status: OBBCAbiProviderScanResult
    let usages: [TokenUsage]
    let conversations: [ConversationRecord]
}

@_cdecl("obb_scan_usage")
public func obb_scan_usage(requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let response: OBBCAbiUsageScanResponse
    do {
        response = try OBBCAbiUsageScanExport.run(requestJSON: requestJSON)
    } catch {
        response = .failure(String(describing: error))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(response),
          let json = String(data: data, encoding: .utf8) else {
        return OBBCAbiMemory.duplicateCString(
            #"{"conversations":[],"error":"encode_failed","ok":false,"providers":[],"usages":[]}"#
        )
    }
    return OBBCAbiMemory.duplicateCString(json)
}

public enum OBBCAbiUsageScanExport {
    public static func run(requestJSON: UnsafePointer<CChar>?) throws -> OBBCAbiUsageScanResponse {
        guard let requestJSON else {
            throw OBBCAbiUsageScanError.missingRequest
        }
        return try run(requestData: Data(String(cString: requestJSON).utf8))
    }

    public static func run(requestData: Data) throws -> OBBCAbiUsageScanResponse {
        let request: OBBCAbiUsageScanRequest
        do {
            request = try JSONDecoder().decode(OBBCAbiUsageScanRequest.self, from: requestData)
        } catch {
            throw OBBCAbiUsageScanError.invalidRequest
        }

        try validate(request)
        return try awaitBlocking { try await scan(request) }
    }

    private static func validate(_ request: OBBCAbiUsageScanRequest) throws {
        let required = [
            request.supportDirectory,
            request.homeDirectory,
            request.claudeProjectsDirectory,
            request.codexHomeDirectory,
            request.cursorSessionsDirectory,
            request.factorySessionsDirectory,
            request.hermesHomeDirectory,
        ]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw OBBCAbiUsageScanError.invalidRequest
        }
    }

    private static func scan(_ request: OBBCAbiUsageScanRequest) async throws -> OBBCAbiUsageScanResponse {
        let fileManager = FileManager.default
        let appPaths = OpenBurnBarAppPaths(
            applicationSupportRoot: URL(fileURLWithPath: request.supportDirectory, isDirectory: true)
        )
        let options = LogParseOptions(includeConversationBodies: request.includeConversationBodies)

        var outputs: [OBBCAbiProviderOutput] = []
        outputs.append(await scanProvider(
            .claudeCode,
            requiredPath: request.claudeProjectsDirectory,
            fileManager: fileManager
        ) {
            try await ClaudeCodeParser(
                fileManager: fileManager,
                appPaths: appPaths,
                projectsDirectoryOverride: URL(fileURLWithPath: request.claudeProjectsDirectory, isDirectory: true)
            ).parse(options: options)
        })
        outputs.append(await scanProvider(
            .codex,
            requiredPath: URL(fileURLWithPath: request.codexHomeDirectory, isDirectory: true)
                .appendingPathComponent(".codex/state_5.sqlite", isDirectory: false).path,
            fileManager: fileManager
        ) {
            try await CodexParser(
                fileManager: fileManager,
                appPaths: appPaths,
                homeDirectoryURL: URL(fileURLWithPath: request.codexHomeDirectory, isDirectory: true)
            ).parse(options: options)
        })
        outputs.append(await scanProvider(
            .cursorAgent,
            requiredPath: request.cursorSessionsDirectory,
            fileManager: fileManager
        ) {
            try await CursorAgentParser(logDirectoryOverride: request.cursorSessionsDirectory).parse(options: options)
        })
        outputs.append(await scanProvider(
            .factory,
            requiredPath: request.factorySessionsDirectory,
            fileManager: fileManager
        ) {
            try await FactoryDroidParser(
                fileManager: fileManager,
                appPaths: appPaths,
                sessionsDirectoryOverride: URL(fileURLWithPath: request.factorySessionsDirectory, isDirectory: true)
            ).parse(options: options)
        })
        outputs.append(await scanProvider(
            .hermes,
            requiredPath: request.hermesHomeDirectory,
            fileManager: fileManager
        ) {
            try await HermesParser(
                fileManager: fileManager,
                hermesRootURL: URL(fileURLWithPath: request.hermesHomeDirectory, isDirectory: true)
            ).parse(options: options)
        })

        let usages = outputs
            .flatMap(\.usages)
            .map(OBBCAbiRuntimeUsageRecord.init)
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
                if lhs.model != rhs.model { return lhs.model < rhs.model }
                return lhs.id < rhs.id
            }
        let conversations = outputs
            .flatMap(\.conversations)
            .map(OBBCAbiRuntimeConversationRecord.init)
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
                return lhs.id < rhs.id
            }

        return OBBCAbiUsageScanResponse(
            ok: true,
            error: nil,
            providers: outputs.map(\.status),
            usages: usages,
            conversations: conversations
        )
    }

    private static func scanProvider(
        _ provider: AgentProvider,
        requiredPath: String,
        fileManager: FileManager,
        operation: () async throws -> ParseResult
    ) async -> OBBCAbiProviderOutput {
        guard fileManager.fileExists(atPath: requiredPath) else {
            return OBBCAbiProviderOutput(
                status: OBBCAbiProviderScanResult(
                    provider: provider.rawValue,
                    status: .missing,
                    usageCount: 0,
                    conversationCount: 0,
                    error: nil
                ),
                usages: [],
                conversations: []
            )
        }

        do {
            let result = try await operation()
            return OBBCAbiProviderOutput(
                status: OBBCAbiProviderScanResult(
                    provider: provider.rawValue,
                    status: .succeeded,
                    usageCount: result.usages.count,
                    conversationCount: result.conversations.count,
                    error: nil
                ),
                usages: result.usages,
                conversations: result.conversations
            )
        } catch {
            return OBBCAbiProviderOutput(
                status: OBBCAbiProviderScanResult(
                    provider: provider.rawValue,
                    status: .failed,
                    usageCount: 0,
                    conversationCount: 0,
                    error: String(describing: error)
                ),
                usages: [],
                conversations: []
            )
        }
    }

    private static func awaitBlocking<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) throws -> T {
        let holder = OBBCAbiUsageScanOutcome<T>()
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

public enum OBBCAbiUsageScanError: Error, CustomStringConvertible, Equatable {
    case missingRequest
    case invalidRequest

    public var description: String {
        switch self {
        case .missingRequest: return "missing required argument: requestJSON"
        case .invalidRequest: return "invalid usage scan request"
        }
    }
}

private final class OBBCAbiUsageScanOutcome<T: Sendable>: Sendable {
    private let outcome = Locked<Result<T, Error>?>(nil)

    func store(_ value: Result<T, Error>) {
        outcome.write(value)
    }

    func take() throws -> T {
        guard let result = outcome.read() else {
            throw OBBCAbiUsageScanError.invalidRequest
        }
        return try result.get()
    }
}
