import Foundation

public enum BurnBarWorkspaceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case remote
    case readonly
    case virtualWorkspace = "virtual_workspace"
    case untrusted
}

public enum BurnBarApprovalPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case userApproval = "user_approval"
}

public enum BurnBarToolKind: String, Codable, CaseIterable, Hashable, Sendable {
    case readFile = "read_file"
    case searchWorkspace = "search_workspace"
    case applyPatch = "apply_patch"
    case runTerminal = "run_terminal"
    // Computer Use — Browser (Path B). See
    // plans/2026-05-16-computer-use-master-plan.md § B.4.
    case browserClick = "browser_click"
    case browserFill = "browser_fill"
    case browserGoto = "browser_goto"
    case browserKey = "browser_key"
    case browserSelect = "browser_select"
    case browserScreenshot = "browser_screenshot"
    case browserExtract = "browser_extract"
    // Computer Use — Mac System (Path C).
    case macInputClick = "mac_input_click"
    case macInputType = "mac_input_type"
    case macInputKey = "mac_input_key"
    case macInputShortcut = "mac_input_shortcut"
    case macInputDragDrop = "mac_input_drag_drop"
    case macInspectAccessibility = "mac_inspect_accessibility"
}

public extension BurnBarToolKind {
    /// The Computer Use tool kinds — used by the daemon's run executor
    /// to detect a request that should route through
    /// `ComputerUseRunCoordinator` instead of the existing companion-tool
    /// dispatcher.
    static let computerUseToolKinds: Set<BurnBarToolKind> = [
        .browserClick, .browserFill, .browserGoto, .browserKey,
        .browserSelect, .browserScreenshot, .browserExtract,
        .macInputClick, .macInputType, .macInputKey,
        .macInputShortcut, .macInputDragDrop, .macInspectAccessibility
    ]

    /// Whether this kind dispatches through Playwright.
    var isBrowserComputerUse: Bool {
        switch self {
        case .browserClick, .browserFill, .browserGoto, .browserKey,
             .browserSelect, .browserScreenshot, .browserExtract:
            return true
        default:
            return false
        }
    }

    /// Whether this kind requires Accessibility permission.
    var isMacComputerUse: Bool {
        switch self {
        case .macInputClick, .macInputType, .macInputKey,
             .macInputShortcut, .macInputDragDrop, .macInspectAccessibility:
            return true
        default:
            return false
        }
    }
}

public struct BurnBarToolDefinition: Codable, Hashable, Sendable {
    public let kind: BurnBarToolKind
    public let displayName: String
    public let approvalPolicy: BurnBarApprovalPolicy
    public let requiresTrustedWorkspace: Bool
    public let requiredCapabilities: [BurnBarWorkspaceCapability]

    public init(
        kind: BurnBarToolKind,
        displayName: String,
        approvalPolicy: BurnBarApprovalPolicy,
        requiresTrustedWorkspace: Bool,
        requiredCapabilities: [BurnBarWorkspaceCapability] = []
    ) {
        self.kind = kind
        self.displayName = displayName
        self.approvalPolicy = approvalPolicy
        self.requiresTrustedWorkspace = requiresTrustedWorkspace
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct BurnBarToolInvocation: Codable, Hashable, Sendable {
    public let callID: String
    public let runID: BurnBarRunID
    public let tool: BurnBarToolKind
    public let arguments: BurnBarJSONValue
    public let requestedBy: BurnBarClientID
    public let requestedAt: Date

    public init(
        callID: String,
        runID: BurnBarRunID,
        tool: BurnBarToolKind,
        arguments: BurnBarJSONValue,
        requestedBy: BurnBarClientID,
        requestedAt: Date
    ) {
        self.callID = callID
        self.runID = runID
        self.tool = tool
        self.arguments = arguments
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
    }
}

public struct BurnBarToolResult: Codable, Hashable, Sendable {
    public let callID: String
    public let runID: BurnBarRunID
    public let succeeded: Bool
    public let output: BurnBarJSONValue?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        callID: String,
        runID: BurnBarRunID,
        succeeded: Bool,
        output: BurnBarJSONValue?,
        errorMessage: String? = nil,
        completedAt: Date
    ) {
        self.callID = callID
        self.runID = runID
        self.succeeded = succeeded
        self.output = output
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }
}

public enum BurnBarToolExecutionErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
    case trustGated = "trust_gated"
    case noWorkspace = "no_workspace"
    case remoteUnsupported = "remote_unsupported"
    case applyFailed = "apply_failed"
    case terminalFailed = "terminal_failed"
    case unknown
}

public struct BurnBarToolExecutionError: Codable, Hashable, Sendable {
    public let code: BurnBarToolExecutionErrorCode
    public let message: String

    public init(code: BurnBarToolExecutionErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BurnBarToolCallStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case cancelled
}

public struct BurnBarToolCallSnapshot: Codable, Hashable, Sendable {
    public let callID: String
    public let runID: BurnBarRunID
    public let tool: BurnBarToolKind
    public let arguments: BurnBarJSONValue
    public let status: BurnBarToolCallStatus
    public let requestedBy: BurnBarClientID
    public let requestedAt: Date
    public let claimedBy: BurnBarClientID?
    public let claimedAt: Date?
    public let completedAt: Date?
    public let output: BurnBarJSONValue?
    public let error: BurnBarToolExecutionError?

    public init(
        callID: String,
        runID: BurnBarRunID,
        tool: BurnBarToolKind,
        arguments: BurnBarJSONValue,
        status: BurnBarToolCallStatus,
        requestedBy: BurnBarClientID,
        requestedAt: Date,
        claimedBy: BurnBarClientID? = nil,
        claimedAt: Date? = nil,
        completedAt: Date? = nil,
        output: BurnBarJSONValue? = nil,
        error: BurnBarToolExecutionError? = nil
    ) {
        self.callID = callID
        self.runID = runID
        self.tool = tool
        self.arguments = arguments
        self.status = status
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
        self.completedAt = completedAt
        self.output = output
        self.error = error
    }
}
