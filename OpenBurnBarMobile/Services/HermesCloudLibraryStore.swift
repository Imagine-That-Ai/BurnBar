import Foundation
import OpenBurnBarCore

struct HermesLibrarySession: Identifiable, Hashable, Sendable {
    let id: String
    let sessionId: String
    let title: String
    let preview: String
    let source: HermesCloudLibrarySource
    let lastActiveAt: Date?
    let documentID: String?
    let inlineTranscript: String?
    let messageCount: Int

    var sourceLabel: String { source.displayName }
}

struct HermesCloudLibraryManifest: Identifiable, Hashable, Sendable {
    let id: String
    let documentID: String
    let sessionId: String
    let title: String
    let projectName: String
    let messageCount: Int
    let updatedAt: Date?
    let startTime: Date?
    let endTime: Date?
}

@MainActor
@Observable
final class HermesCloudLibraryStore {
    var sessions: [HermesLibrarySession] = []
    var isLoading = false
    var lastError: String?

    private let repository: FirestoreRepository
    private let iCloudReader: MobileICloudHermesLibraryReader

    init(
        repository: FirestoreRepository = .shared,
        iCloudReader: MobileICloudHermesLibraryReader = MobileICloudHermesLibraryReader()
    ) {
        self.repository = repository
        self.iCloudReader = iCloudReader
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        var merged: [HermesLibrarySession] = []
        do {
            let manifests = try await repository.fetchHermesCloudLibrarySessions(limit: 120)
            merged += manifests.map { manifest in
                HermesLibrarySession(
                    id: "firebase:\(manifest.documentID)",
                    sessionId: manifest.sessionId,
                    title: manifest.title.nilIfBlank ?? manifest.projectName.nilIfBlank ?? "Hermes conversation",
                    preview: manifest.projectName.nilIfBlank ?? manifest.sessionId,
                    source: .firebase,
                    lastActiveAt: manifest.endTime ?? manifest.updatedAt ?? manifest.startTime,
                    documentID: manifest.documentID,
                    inlineTranscript: nil,
                    messageCount: manifest.messageCount
                )
            }
        } catch {
            lastError = error.localizedDescription
        }

        let iCloudSessions = await iCloudReader.fetchSessions()
        merged += iCloudSessions

        sessions = Self.deduplicate(merged)
    }

    func transcript(for session: HermesLibrarySession) async throws -> String {
        if let inline = session.inlineTranscript, !inline.isEmpty {
            return inline
        }
        guard session.source == .firebase, let documentID = session.documentID else {
            return ""
        }
        return try await repository.fetchSessionLogBody(documentID: documentID)
    }

    static func deduplicate(_ sessions: [HermesLibrarySession]) -> [HermesLibrarySession] {
        var byKey: [String: HermesLibrarySession] = [:]
        for session in sessions {
            let key = session.sessionId.nilIfBlank ?? "\(session.title)|\(session.lastActiveAt?.description ?? session.id)"
            let existing = byKey[key]
            if existing == nil || session.source == .firebase {
                byKey[key] = session
            }
        }
        return byKey.values.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }
}

struct MobileICloudHermesLibraryReader: Sendable {
    private let fileManager: FileManager
    private let containerIdentifier = "iCloud.com.openburnbar.app"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fetchSessions() async -> [HermesLibrarySession] {
        guard let root = mirrorRootDirectoryURL() else { return [] }
        return await Task.detached(priority: .utility) {
            Self.extractSessions(from: root)
        }.value
    }

    private func mirrorRootDirectoryURL() -> URL? {
        guard let base = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return nil
        }
        return base
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("SessionMirror", isDirectory: true)
            .appendingPathComponent("Hermes", isDirectory: true)
    }

    static func extractSessions(from root: URL, fileManager: FileManager = .default) -> [HermesLibrarySession] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [HermesLibrarySession] = []
        for case let file as URL in enumerator {
            let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let ext = file.pathExtension.lowercased()
            guard ext == "json" || ext == "jsonl" else { continue }
            downloadUbiquitousItemIfNeeded(file, fileManager: fileManager)
            if let session = parseSessionFile(file) {
                sessions.append(session)
            }
        }
        return sessions.sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
    }

    private static func parseSessionFile(_ file: URL) -> HermesLibrarySession? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return nil }
        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var messages: [(role: String, content: String)] = []
        var explicitTitle: String?
        var explicitSessionId: String?
        var explicitUpdatedAt: Date?

        if file.pathExtension.lowercased() == "jsonl" {
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                appendMessage(from: object, to: &messages)
            }
        } else if let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            explicitTitle = object["title"] as? String
            explicitSessionId = object["session_id"] as? String ?? object["sessionId"] as? String
            if let updated = object["updated_at"] as? String {
                explicitUpdatedAt = ISO8601DateFormatter().date(from: updated)
            }
            if let rawMessages = object["messages"] as? [[String: Any]] {
                for raw in rawMessages {
                    appendMessage(from: raw, to: &messages)
                }
            } else {
                appendMessage(from: object, to: &messages)
            }
        }

        let transcript = messages.isEmpty
            ? text
            : messages.map { "\($0.role.capitalized): \($0.content)" }.joined(separator: "\n\n")
        let firstUser = messages.first(where: { $0.role == "user" })?.content.nilIfBlank
        let lastMessage = messages.last?.content.nilIfBlank
        let sessionId = file.deletingPathExtension().lastPathComponent

        return HermesLibrarySession(
            id: "icloud:\(file.path)",
            sessionId: explicitSessionId?.nilIfBlank ?? sessionId,
            title: explicitTitle?.nilIfBlank ?? firstUser.map { String($0.prefix(90)) } ?? sessionId,
            preview: lastMessage.map { String($0.prefix(160)) } ?? "Mirrored from iCloud Drive",
            source: .iCloud,
            lastActiveAt: explicitUpdatedAt ?? modifiedAt,
            documentID: nil,
            inlineTranscript: transcript,
            messageCount: max(messages.count, 1)
        )
    }

    private static func appendMessage(from object: [String: Any], to messages: inout [(role: String, content: String)]) {
        let role = (object["role"] as? String ?? object["type"] as? String ?? "").lowercased()
        let rawContent = object["content"] ?? object["text"] ?? object["message"]
        let content = stringContent(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        messages.append((role.isEmpty ? "message" : role, content))
    }

    private static func downloadUbiquitousItemIfNeeded(_ file: URL, fileManager: FileManager) {
        guard let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current,
              values.ubiquitousItemDownloadingStatus != .downloaded else {
            return
        }
        try? fileManager.startDownloadingUbiquitousItem(at: file)
    }

    private static func stringContent(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let parts as [Any]:
            return parts.map { stringContent($0) }.joined(separator: "\n")
        case let object as [String: Any]:
            if let text = object["text"] as? String { return text }
            if let content = object["content"] as? String { return content }
            return ""
        default:
            return ""
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
