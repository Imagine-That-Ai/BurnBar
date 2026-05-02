import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {

    func exportControllerActivitySnapshot() {
        guard let dataStore else { return }

        do {
            let snapshot = try makeControllerActivitySnapshot(from: dataStore)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try dependencies.fileManager.createDirectory(
                at: paths.controllerActivitySnapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: paths.controllerActivitySnapshotURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func makeControllerActivitySnapshot(
        from dataStore: DataStore
    ) throws -> BurnBarControllerActivitySnapshot {
        let conversations = try dataStore.fetchConversations(limit: 250)
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let recentUsages = dataStore.usages(in: start...Date())

        let conversationProjects = conversations.map(\.projectName).filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let usageProjects = recentUsages.map(\.projectName).filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let allProjectNames = Set(conversationProjects + usageProjects)

        let projects = allProjectNames.compactMap { projectName -> BurnBarControllerActivityProject? in
            let slug = Self.slug(for: projectName)
            guard slug.isEmpty == false else { return nil }

            let projectConversations = conversations
                .filter { Self.slug(for: $0.projectName) == slug }
                .sorted { Self.activityDate(for: $0) > Self.activityDate(for: $1) }
            let projectUsages = recentUsages
                .filter { Self.slug(for: $0.projectName) == slug }
                .sorted { $0.endTime > $1.endTime }

            let latestConversation = projectConversations.first
            let latestActivityAt = max(
                latestConversation.map(Self.activityDate(for:)) ?? .distantPast,
                projectUsages.first?.endTime ?? .distantPast
            )
            let summary = latestConversation?.summary?.nonEmpty
                ?? latestConversation?.summaryTitle?.nonEmpty
                ?? latestConversation.map { $0.inferredTaskTitle.nonEmpty }.flatMap { $0 }
                ?? "Recent OpenBurnBar activity is available for review."

            return BurnBarControllerActivityProject(
                projectSlug: slug,
                displayName: projectName,
                summary: summary,
                latestActivityAt: latestActivityAt == .distantPast ? nil : latestActivityAt,
                latestConversationID: latestConversation?.id,
                latestConversationSessionID: latestConversation.map { BurnBarSessionID(rawValue: $0.sessionId) },
                latestConversationTitle: latestConversation?.summaryTitle?.nonEmpty
                    ?? latestConversation.map { $0.inferredTaskTitle.nonEmpty }.flatMap { $0 },
                latestConversationSummary: latestConversation?.summary?.nonEmpty,
                latestQuestionPrompt: nil,
                sessionCountLast7Days: Set(projectUsages.map(\.sessionId)).count,
                totalCostLast7Days: projectUsages.reduce(0) { $0 + $1.cost },
                totalTokensLast7Days: projectUsages.reduce(0) { $0 + $1.totalTokens }
            )
        }
        .sorted { ($0.latestActivityAt ?? .distantPast) > ($1.latestActivityAt ?? .distantPast) }

        return BurnBarControllerActivitySnapshot(
            generatedAt: Date(),
            activeProjectSlug: projects.first?.projectSlug,
            projects: projects
        )
    }

    static func telegramTokenHint(for token: String) -> String {
        guard token.count > 8 else { return token }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    static func slug(for projectName: String) -> String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        let scalars = trimmed.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? trimmed.lowercased().replacingOccurrences(of: " ", with: "-") : collapsed
    }

    static func activityDate(for conversation: ConversationRecord) -> Date {
        conversation.endTime ?? conversation.startTime ?? conversation.indexedAt
    }
}
