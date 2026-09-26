import Foundation

/// Run-resume RPC response (3.2: extracted from Kernel RPC contracts; the CLI agent resume presentation in InboxModels is its sole consumer).
public struct BurnBarRunResumeResponse: Codable, Sendable, Hashable {
    public let kind: String
    public let argv: [String]?
    public let targetHarness: String?
    public let targetArgv: [String]?
    public let briefingMD: String?
    public let briefingPath: String?
    public let workingDirectory: String?
    public let note: String?
    public let pid: Int?
    public let cleanupAfterSeconds: Int?
    public let errorCode: String?
    public let errorRecovery: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case argv
        case targetHarness = "target_harness"
        case targetArgv = "target_argv"
        case briefingMD = "briefing_md"
        case briefingPath = "briefing_path"
        case workingDirectory = "working_directory"
        case note
        case pid
        case cleanupAfterSeconds = "cleanup_after_seconds"
        case errorCode = "code"
        case errorRecovery = "recovery"
    }

    public init(
        kind: String,
        argv: [String]? = nil,
        targetHarness: String? = nil,
        targetArgv: [String]? = nil,
        briefingMD: String? = nil,
        briefingPath: String? = nil,
        workingDirectory: String? = nil,
        note: String? = nil,
        pid: Int? = nil,
        cleanupAfterSeconds: Int? = nil,
        errorCode: String? = nil,
        errorRecovery: String? = nil
    ) {
        self.kind = kind
        self.argv = argv
        self.targetHarness = targetHarness
        self.targetArgv = targetArgv
        self.briefingMD = briefingMD
        self.briefingPath = briefingPath
        self.workingDirectory = workingDirectory
        self.note = note
        self.pid = pid
        self.cleanupAfterSeconds = cleanupAfterSeconds
        self.errorCode = errorCode
        self.errorRecovery = errorRecovery
    }
}
