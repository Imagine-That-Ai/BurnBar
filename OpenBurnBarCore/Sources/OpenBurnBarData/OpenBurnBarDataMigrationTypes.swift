import Foundation

enum SourceArtifactStatus: String, Codable, CaseIterable, Sendable {
    case active
    case deleted
}

enum SharedArtifactSyncStatus: String, Codable, CaseIterable, Sendable {
    case synced
    case pendingUpload = "pending_upload"
    case pendingPull = "pending_pull"
    case conflicted
    case failed
}

struct ChatTranscriptPiece: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case reasoning
        case refusal
        case toolUse
        case toolResult
    }

    let id: String
    let kind: Kind
    var value: String
    let detail: String?

    init(id: String = UUID().uuidString, kind: Kind, value: String, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.detail = detail
    }
}

enum OpenBurnBarIdentity {
    static let deviceIDKey = "openburnbar.device.id"
}

enum DeviceHardwareIcon {
    static let localHardwareModel = "linux"
}
