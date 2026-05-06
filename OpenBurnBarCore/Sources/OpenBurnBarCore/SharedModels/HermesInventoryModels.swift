import Foundation

public enum HermesCloudLibrarySource: String, Codable, Sendable, Equatable, CaseIterable {
    case liveHost
    case firebase
    case iCloud

    public var displayName: String {
        switch self {
        case .liveHost: return "Mac Relay"
        case .firebase: return "OpenBurnBar Cloud"
        case .iCloud: return "iCloud"
        }
    }
}

public struct HermesInventoryImportSummary: Codable, Sendable, Equatable {
    public let conversationCount: Int
    public let usageEventCount: Int
    public let firstActivityAt: Date?
    public let lastActivityAt: Date?
    public let estimatedTranscriptBytes: Int

    public init(
        conversationCount: Int,
        usageEventCount: Int,
        firstActivityAt: Date? = nil,
        lastActivityAt: Date? = nil,
        estimatedTranscriptBytes: Int = 0
    ) {
        self.conversationCount = conversationCount
        self.usageEventCount = usageEventCount
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.estimatedTranscriptBytes = estimatedTranscriptBytes
    }

    public static let empty = HermesInventoryImportSummary(
        conversationCount: 0,
        usageEventCount: 0
    )
}

public struct HermesInventoryImportDecision: Codable, Sendable, Equatable {
    public var importLocally: Bool
    public var backupToOpenBurnBarCloud: Bool
    public var mirrorToICloud: Bool

    public init(
        importLocally: Bool = true,
        backupToOpenBurnBarCloud: Bool = true,
        mirrorToICloud: Bool = false
    ) {
        self.importLocally = importLocally
        self.backupToOpenBurnBarCloud = backupToOpenBurnBarCloud
        self.mirrorToICloud = mirrorToICloud
    }
}

public struct HermesInventoryImportProgress: Codable, Sendable, Equatable {
    public let importedConversationCount: Int
    public let skippedConversationCount: Int
    public let importedUsageEventCount: Int
    public let enqueuedProjectionJobCount: Int
    public let cloudBackupRequested: Bool
    public let iCloudMirrorRequested: Bool

    public init(
        importedConversationCount: Int = 0,
        skippedConversationCount: Int = 0,
        importedUsageEventCount: Int = 0,
        enqueuedProjectionJobCount: Int = 0,
        cloudBackupRequested: Bool = false,
        iCloudMirrorRequested: Bool = false
    ) {
        self.importedConversationCount = importedConversationCount
        self.skippedConversationCount = skippedConversationCount
        self.importedUsageEventCount = importedUsageEventCount
        self.enqueuedProjectionJobCount = enqueuedProjectionJobCount
        self.cloudBackupRequested = cloudBackupRequested
        self.iCloudMirrorRequested = iCloudMirrorRequested
    }
}
