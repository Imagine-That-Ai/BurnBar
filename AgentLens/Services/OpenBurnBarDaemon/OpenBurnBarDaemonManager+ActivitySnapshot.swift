import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {

    private static let controllerActivitySnapshotFreshness: TimeInterval = 60
    // Project migration must see the full bounded session window, not only the
    // latest context rows. The daemon ingests this snapshot to turn inferred
    // activity projects into stable registry entries; capping it at 80 silently
    // orphaned older projects and made the 10k-session acceptance gate false.
    private static let controllerActivityConversationLimit = 10_000

    func exportControllerActivitySnapshot() async {
        if let existingTask = controllerActivitySnapshotExportTask {
            await existingTask.value
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performControllerActivitySnapshotExport()
        }
        controllerActivitySnapshotExportTask = task
        await task.value
        controllerActivitySnapshotExportTask = nil
    }

    private func performControllerActivitySnapshotExport() async {
        guard let dataStore else { return }

        do {
            let snapshot = try await makeControllerActivitySnapshot(from: dataStore)
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

    func exportControllerActivitySnapshotIfStale() async {
        // try?-ok(stale-check falls through to regenerate)
        if let attributes = try? dependencies.fileManager.attributesOfItem(atPath: paths.controllerActivitySnapshotURL.path),
           let modifiedAt = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modifiedAt) < Self.controllerActivitySnapshotFreshness {
            return
        }
        await exportControllerActivitySnapshot()
    }

    func makeControllerActivitySnapshot(
        from dataStore: DataStore
    ) async throws -> BurnBarControllerActivitySnapshot {
        // Fetch on the main-actor facade, then assemble off-main. The previous
        // nested filter × slug implementation was O(projects × conversations)
        // and froze the UI when refreshHealth ran during dashboard open with a
        // large history (up to 10k conversations).
        let generatedAt = Date()
        let conversations = try await dataStore.fetchConversationActivitySummaries(
            limit: Self.controllerActivityConversationLimit
        )
        let start = Calendar.current.date(byAdding: .day, value: -7, to: generatedAt)
            ?? generatedAt.addingTimeInterval(-7 * 24 * 60 * 60)
        // Controller activity is background state, so read its exact bounded
        // window directly from the indexed ledger instead of depending on the
        // dashboard's demand-loaded presentation cache.
        let recentUsages = try await dataStore.fetchUsage(
            startingIn: start..<generatedAt,
            limit: Int.max
        )

        return await Task.detached(priority: .utility) {
            Self.buildControllerActivitySnapshot(
                conversations: conversations,
                recentUsages: recentUsages,
                generatedAt: generatedAt
            )
        }.value
    }

    /// Pure O(n) assembly: slug each row once, group once, emit projects.
    nonisolated static func buildControllerActivitySnapshot(
        conversations: [ConversationActivitySummary],
        recentUsages: [TokenUsage],
        generatedAt: Date = Date()
    ) -> BurnBarControllerActivitySnapshot {
        struct ConversationBucket {
            var displayName: String
            var conversations: [ConversationActivitySummary] = []
        }
        struct UsageBucket {
            var usages: [TokenUsage] = []
        }

        var conversationBuckets: [String: ConversationBucket] = [:]
        conversationBuckets.reserveCapacity(min(conversations.count, 256))
        for conversation in conversations {
            let slug = slug(for: conversation.projectName)
            guard !slug.isEmpty else { continue }
            var bucket = conversationBuckets[slug] ?? ConversationBucket(displayName: conversation.projectName)
            if bucket.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bucket.displayName = conversation.projectName
            }
            bucket.conversations.append(conversation)
            conversationBuckets[slug] = bucket
        }

        var usageBuckets: [String: UsageBucket] = [:]
        usageBuckets.reserveCapacity(min(recentUsages.count, 256))
        for usage in recentUsages {
            let slug = slug(for: usage.projectName)
            guard !slug.isEmpty else { continue }
            var bucket = usageBuckets[slug] ?? UsageBucket()
            bucket.usages.append(usage)
            usageBuckets[slug] = bucket
        }

        var allSlugs = Set(conversationBuckets.keys)
        allSlugs.formUnion(usageBuckets.keys)

        let projects: [BurnBarControllerActivityProject] = allSlugs.compactMap { slug in
            let conversationBucket = conversationBuckets[slug]
            let usages = usageBuckets[slug]?.usages ?? []
            let projectConversations = (conversationBucket?.conversations ?? [])
                .sorted { activityDate(for: $0) > activityDate(for: $1) }
            let projectUsages = usages.sorted { $0.endTime > $1.endTime }

            let displayName = conversationBucket?.displayName
                ?? projectUsages.first?.projectName
                ?? slug
            let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDisplay.isEmpty else { return nil }

            let latestConversation = projectConversations.first
            let latestActivityAt = max(
                latestConversation.map(activityDate(for:)) ?? .distantPast,
                projectUsages.first?.endTime ?? .distantPast
            )
            let summary = latestConversation?.summary?.nonEmpty
                ?? latestConversation?.summaryTitle?.nonEmpty
                ?? latestConversation.map { $0.inferredTaskTitle.nonEmpty }.flatMap { $0 }
                ?? "Recent OpenBurnBar activity is available for review."

            return BurnBarControllerActivityProject(
                projectSlug: slug,
                displayName: trimmedDisplay,
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
            generatedAt: generatedAt,
            activeProjectSlug: projects.first?.projectSlug,
            projects: projects
        )
    }

    static func telegramTokenHint(for token: String) -> String {
        guard token.count > 8 else { return token }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    /// Single-pass daemon-safe slug: ASCII alphanumerics are kept, every other
    /// run collapses to `-`, and the result stays within Mission Control's
    /// 96-byte identifier limit. Punctuation-only and non-ASCII-only names are
    /// not projects; returning an empty slug keeps them out of the derived
    /// activity snapshot instead of making every controller RPC reject it.
    nonisolated static func slug(for projectName: String) -> String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let maxSlugBytes = 96
        var result = String()
        result.reserveCapacity(min(trimmed.utf8.count, maxSlugBytes))
        var pendingHyphen = false
        for scalar in trimmed.lowercased().unicodeScalars {
            let value = scalar.value
            let isASCIIDigit = value >= 48 && value <= 57
            let isASCIILowercaseLetter = value >= 97 && value <= 122
            if isASCIIDigit || isASCIILowercaseLetter {
                if pendingHyphen && !result.isEmpty {
                    guard result.utf8.count + 2 <= maxSlugBytes else { break }
                    result.append("-")
                }
                guard result.utf8.count < maxSlugBytes else { break }
                result.unicodeScalars.append(scalar)
                pendingHyphen = false
            } else if !result.isEmpty {
                pendingHyphen = true
            }
        }

        return result
    }

    nonisolated static func activityDate(for conversation: ConversationActivitySummary) -> Date {
        conversation.endTime ?? conversation.startTime ?? conversation.indexedAt
    }
}
