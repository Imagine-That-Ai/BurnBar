import Foundation

// Linux/OpenBurnBarData persists chat attachment metadata, but the broader
// OpenBurnBarCore target pulls in many app-facing surfaces that this storage
// lane does not need. Keep the wire-compatible attachment model local here so
// the datastore can encode/decode the existing JSON payloads without the full
// app-core dependency graph.

public enum HermesAttachmentKind: String, Codable, Sendable, Hashable {
    case image
    case textDocument
    case pdf
    case audio
    case video
    case generic
}

public struct HermesAttachment: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var kind: HermesAttachmentKind
    public var displayName: String
    public var mimeType: String
    public var byteSize: Int
    public var workspaceRelativePath: String
    public var thumbnailPNG: Data?
    public var extractedTextPreview: String?

    public init(
        id: String = UUID().uuidString,
        kind: HermesAttachmentKind,
        displayName: String,
        mimeType: String,
        byteSize: Int,
        workspaceRelativePath: String,
        thumbnailPNG: Data? = nil,
        extractedTextPreview: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.workspaceRelativePath = workspaceRelativePath
        self.thumbnailPNG = thumbnailPNG
        self.extractedTextPreview = extractedTextPreview
    }
}
