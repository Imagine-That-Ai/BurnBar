import Foundation

/// File refs inside a mission sealedPayload. Rules cannot see inside the seal.
public struct CLIAgentMissionAttachmentRef: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var contentBlake3: String
    public var displayName: String
    public var byteCount: Int64
    public var transport: String
    public var contentKeyBase64: String?

    public init(
        id: String,
        contentBlake3: String,
        displayName: String,
        byteCount: Int64,
        transport: String,
        contentKeyBase64: String? = nil
    ) {
        self.id = id
        self.contentBlake3 = contentBlake3
        self.displayName = displayName
        self.byteCount = byteCount
        self.transport = transport
        self.contentKeyBase64 = contentKeyBase64
    }
}
