import Foundation

/// Stable privileged-input dispatch contract shared by Unix socket (legacy), XPC, and WS2 capability tokens.
public struct PrivilegedInputDispatchRequest: Codable, Sendable, Equatable {
    public var operation: String
    public var password: String?
    public var kind: String?
    public var displayX: Int?
    public var displayY: Int?
    public var dragEndX: Int?
    public var dragEndY: Int?
    public var deltaX: Int?
    public var deltaY: Int?
    public var mouseButton: Int?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?

    public init(
        operation: String,
        password: String? = nil,
        kind: String? = nil,
        displayX: Int? = nil,
        displayY: Int? = nil,
        dragEndX: Int? = nil,
        dragEndY: Int? = nil,
        deltaX: Int? = nil,
        deltaY: Int? = nil,
        mouseButton: Int? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil
    ) {
        self.operation = operation
        self.password = password
        self.kind = kind
        self.displayX = displayX
        self.displayY = displayY
        self.dragEndX = dragEndX
        self.dragEndY = dragEndY
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.mouseButton = mouseButton
        self.text = text
        self.key = key
        self.modifiers = modifiers
    }
}

public struct PrivilegedInputDispatchResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var version: String
    public var error: String?

    public init(ok: Bool, version: String = "1", error: String? = nil) {
        self.ok = ok
        self.version = version
        self.error = error
    }
}

/// When the Virtual HID bridge forwards a socket request over XPC, the leaf re-validates the
/// original peer using this embedded audit token (TOCTOU-safe at accept time on the bridge).
public struct PrivilegedInputDispatchEnvelope: Codable, Sendable, Equatable {
    public var request: PrivilegedInputDispatchRequest
    public var peerAuditToken: Data?

    public init(request: PrivilegedInputDispatchRequest, peerAuditToken: Data? = nil) {
        self.request = request
        self.peerAuditToken = peerAuditToken
    }
}
