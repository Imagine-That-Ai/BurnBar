import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transcript Role Filter

private enum TranscriptRoleFilter: String, CaseIterable {
    case all = "All"
    case user = "You"
    case assistant = "Assistant"

    var matchesBlock: (TranscriptBlock) -> Bool {
        switch self {
        case .all: return { _ in true }
        case .user: return { $0.kind == .userMessage }
        case .assistant: return { $0.kind == .assistantMessage || $0.kind == .toolUse || $0.kind == .codeBlock }
        }
    }

    var icon: String {
        switch self {
        case .all: return "text.bubble"
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        }
    }
}

private struct TranscriptChunk: Identifiable {
    let id: Int
    let primaryKind: TranscriptBlock.Kind
    let blocks: [TranscriptBlock]
    /// Index range in the full block array for context expansion
    let sourceRange: Range<Int>

    var preview: String {
        let firstContent = blocks.first(where: { $0.kind == .userMessage || $0.kind == .assistantMessage })?.content ?? blocks.first?.content ?? ""
        let maxLen = 120
        if firstContent.count <= maxLen { return firstContent }
        return String(firstContent.prefix(maxLen)) + "..."
    }

    var blockCount: Int {
        blocks.filter { $0.kind == .userMessage || $0.kind == .assistantMessage }.count
    }
}

// MARK: - Session Log Detail Pane

struct SessionLogDetailPane: View {
    let record: ConversationRecord
    var dataStore: DataStore
    var operatingLayer: OpenBurnBarOperatingLayer?
    var overrideBody: String?
    var jumpTarget: ConversationJumpTarget?
    /// Dominant model from `token_usage` (`sessionModelMap`); best for provider sessions.
    var dominantModelKey: String?
    /// When usage has no model row (e.g. CLI assistant + Hermes), use the live chat model id.
    var preferredChatModelKey: String?

    @State private var markdownBody = ""
    @State private var copyConfirmed = false
    @State private var transcriptFilter: TranscriptRoleFilter = .all
    @State private var expandedChunkIndex: Int?
    @State private var answerDrafts: [String: String] = [:]

    private var accentColor: Color {
        record.sourceType == .cliAssistant
            ? DesignSystem.Colors.whimsy
            : DesignSystem.Colors.amber
    }

    /// Model id for assistant-turn branding (vendor logo in transcript).
    private var assistantModelKeyForBadge: String? {
        if let m = dominantModelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return m }
        if let m = record.summaryModel?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return m }
        if record.sourceType == .cliAssistant,
           let m = preferredChatModelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            return m
        }
        return nil
    }

    @ViewBuilder
    private func assistantAvatarBadge(size: CGFloat = 20) -> some View {
        let logoSize = max(12, size * 0.7)
        if let key = assistantModelKeyForBadge {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                ModelProviderLogoView(modelKey: key, size: logoSize, fallbackSymbolColor: accentColor)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: size, height: size)
                .background(accentColor.opacity(0.12))
                .clipShape(Circle())
        }
    }

    private var displayTitle: String {
        if let summaryTitle = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryTitle.isEmpty {
            return summaryTitle
        }
        return record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle
    }

    private var relatedPendingQuestions: [OpenBurnBarControllerQuestion] {
        guard let operatingLayer else { return [] }
        let runtime = operatingLayer.snapshot.controllerRuntime
        return runtime.pendingQuestions.filter { question in
            if let sessionID = question.sessionID, sessionID == record.sessionId { return true }
            return question.projectName == record.projectName
        }
    }

    private var relatedMission: OpenBurnBarControllerMissionRecord? {
        guard let operatingLayer else { return nil }
        let runtime = operatingLayer.snapshot.controllerRuntime
        return runtime.missions.first(where: { $0.projectName == record.projectName }) ?? runtime.missions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            if relatedPendingQuestions.isEmpty == false {
                controllerQuestionPanel
            }
            if let relatedMission {
                controllerMissionPanel(relatedMission)
            }
            if let jumpTarget {
                jumpTargetCard(jumpTarget)
            }
            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            structuredTranscriptView(blocks: TranscriptBlockParser.parse(record.fullText))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .task { buildMarkdown() }
        .onChange(of: record.id) { _, _ in
            transcriptFilter = .all
            expandedChunkIndex = nil
        }
        .onChange(of: overrideBody) { _, newBody in
            if let newBody, !newBody.isEmpty { markdownBody = newBody }
        }
    }

    private var controllerQuestionPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Pending Questions")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Spacer()
                if let runtime = operatingLayer?.snapshot.controllerRuntime {
                    Text(runtime.source.label)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }

            ForEach(relatedPendingQuestions) { question in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if question.isUnread {
                                    Circle()
                                        .fill(DesignSystem.Colors.ember)
                                        .frame(width: 7, height: 7)
                                }
                                Text(question.title)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                if let stageLabel = question.stageLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   stageLabel.isEmpty == false {
                                    Text(stageLabel)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.blaze)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(DesignSystem.Colors.blaze.opacity(0.12)))
                                }
                            }
                            Text(question.prompt)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if question.notificationCount > 0 {
                            Text("Nudged \(question.notificationCount)x")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }

                    if let rawHint = question.evidenceHint {
                        let hint = rawHint.trimmingCharacters(in: .whitespacesAndNewlines)
                        if hint.isEmpty == false {
                            Text(hint)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }

                    if let deepLink = question.deepLink {
                        HStack(spacing: 4) {
                            Image(systemName: icon(for: deepLink.kind))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.whimsy)
                            Text(deepLink.title)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                            if let subtitle = deepLink.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                               subtitle.isEmpty == false {
                                Text("• \(subtitle)")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                    }

                    if question.suggestedOptions.isEmpty == false {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            ForEach(question.suggestedOptions.prefix(2)) { option in
                                Button {
                                    Task {
                                        await operatingLayer?.answerPendingQuestion(
                                            id: question.id,
                                            answer: option.answer,
                                            selectedOptionID: option.id
                                        )
                                        answerDrafts[question.id] = ""
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title)
                                            .font(DesignSystem.Typography.tiny)
                                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        if let detail = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                                           detail.isEmpty == false {
                                            Text(detail)
                                                .font(DesignSystem.Typography.tiny)
                                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.horizontal, DesignSystem.Spacing.sm)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .fill(DesignSystem.Colors.surface.opacity(0.8))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        TextField(
                            {
                                if let placeholder = question.answerPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   placeholder.isEmpty == false {
                                    return placeholder
                                }
                                return "Record an operator answer…"
                            }(),
                            text: Binding(
                                get: { answerDrafts[question.id] ?? "" },
                                set: { answerDrafts[question.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        Button("Answer") {
                            let answer = answerDrafts[question.id] ?? ""
                            Task {
                                await operatingLayer?.answerPendingQuestion(id: question.id, answer: answer)
                                answerDrafts[question.id] = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.surfaceElevated.opacity(0.72),
                            question.isUnread ? DesignSystem.Colors.ember.opacity(0.08) : DesignSystem.Colors.surface.opacity(0.6)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }

            if let feedback = operatingLayer?.controllerFeedback {
                Text(feedback.message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(feedback.tone.color)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.bottom, DesignSystem.Spacing.lg)
    }

    private func controllerMissionPanel(_ mission: OpenBurnBarControllerMissionRecord) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Mission Runtime")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Spacer()
                Text(mission.state.label)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(mission.state.color)
                if let takeoverState = mission.latestTakeoverState {
                    Text("• \(takeoverState.label)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(takeoverState.color)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(mission.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(trimmedValue(mission.packetSummary) ?? mission.summary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    missionRuntimePill(title: "Burn", value: mission.burnCostUSD.formatAsCost(), color: DesignSystem.Colors.hermesAureate)
                    if mission.packetRunCount > 0 {
                        missionRuntimePill(title: "Runs", value: "\(mission.packetRunCount)", color: DesignSystem.Colors.blaze)
                    }
                    if mission.takeoverCount > 0 {
                        missionRuntimePill(
                            title: "Takeovers",
                            value: "\(mission.takeoverCount)",
                            color: mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze
                        )
                    }
                }

                if let activeRunID = trimmedValue(mission.activeRunID) {
                    missionRuntimeRow(icon: "point.3.filled.connected.trianglepath.dotted", title: "Run", value: activeRunID)
                }
                if let latestResult = trimmedValue(mission.latestResultSummary) {
                    missionRuntimeRow(icon: "checklist.checked", title: "Latest result", value: latestResult)
                }
                if let takeoverReason = trimmedValue(mission.latestTakeoverReason) {
                    missionRuntimeRow(
                        icon: "arrow.triangle.branch",
                        title: "Takeover",
                        value: takeoverReason,
                        accent: mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze
                    )
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.surfaceElevated.opacity(0.76),
                        (mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze).opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.bottom, DesignSystem.Spacing.lg)
    }

    @ViewBuilder
    private func missionRuntimePill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(color)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.surface.opacity(0.85))
        )
    }

    @ViewBuilder
    private func missionRuntimeRow(icon: String, title: String, value: String, accent: Color = DesignSystem.Colors.textPrimary) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 14, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Text(value)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(for kind: OpenBurnBarControllerQuestionDeepLinkKind) -> String {
        switch kind {
        case .sessionLog: return "doc.text.magnifyingglass"
        case .dashboard: return "square.grid.2x2"
        case .project: return "folder"
        case .settings: return "gearshape"
        }
    }

    private func trimmedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    // MARK: - Structured Transcript

    @ViewBuilder
    private func structuredTranscriptView(blocks: [TranscriptBlock]) -> some View {
        VStack(spacing: 0) {
            transcriptFilterBar(blocks: blocks)

            Divider().background(DesignSystem.Colors.border.opacity(0.3))

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    if record.sourceType == .providerLog {
                        transcriptMetadataCard
                    }

                    if let summary = record.summary, !summary.isEmpty {
                        transcriptSummaryCard(summary)
                    }

                    if transcriptFilter == .all {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                            transcriptBlock(block)
                                .id("block-\(idx)-\(block.kind)")
                        }
                    } else {
                        let chunks = buildChunks(from: blocks, filter: transcriptFilter)
                        ForEach(chunks) { chunk in
                            transcriptChunkView(chunk, allBlocks: blocks)
                        }
                    }

                    if blocks.isEmpty && !record.fullText.isEmpty {
                        Text(.init(sessionLogFallbackMarkdown))
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .defaultScrollAnchor(.top)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// When the parser yields no blocks, still render stored markdown (headings, lists) instead of plain text.
    private var sessionLogFallbackMarkdown: String {
        let raw = TranscriptBlockParser.stripSystemTags(record.fullText)
        if markdownBody.isEmpty == false { return markdownBody }
        if record.sourceType == .cliAssistant { return raw }
        return SessionLogMarkdownFormatter.markdown(for: record)
    }

    // MARK: - Filter Bar

    private func transcriptFilterBar(blocks: [TranscriptBlock]) -> some View {
        let userCount = blocks.filter { $0.kind == .userMessage }.count
        let assistantCount = blocks.filter { $0.kind == .assistantMessage }.count

        return HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(TranscriptRoleFilter.allCases, id: \.rawValue) { filter in
                let isSelected = transcriptFilter == filter
                let count: Int? = {
                    switch filter {
                    case .all: return nil
                    case .user: return userCount
                    case .assistant: return assistantCount
                    }
                }()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if transcriptFilter == filter && filter != .all {
                            transcriptFilter = .all
                            expandedChunkIndex = nil
                        } else {
                            transcriptFilter = filter
                            expandedChunkIndex = nil
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(filter.rawValue)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.medium)
                        if let count {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(isSelected ? .white.opacity(0.7) : DesignSystem.Colors.textMuted)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background {
                        Capsule(style: .continuous)
                            .fill(isSelected ? filterColor(for: filter) : DesignSystem.Colors.surface.opacity(0.6))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isSelected ? filterColor(for: filter).opacity(0.6) : DesignSystem.Colors.border.opacity(0.3),
                                lineWidth: 0.5
                            )
                    }
                    .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func filterColor(for filter: TranscriptRoleFilter) -> Color {
        switch filter {
        case .all: return DesignSystem.Colors.textSecondary
        case .user: return DesignSystem.Colors.whimsy
        case .assistant: return accentColor
        }
    }

    // MARK: - Chunk Building

    private func buildChunks(from blocks: [TranscriptBlock], filter: TranscriptRoleFilter) -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        var i = 0
        var chunkId = 0

        while i < blocks.count {
            let block = blocks[i]
            if filter.matchesBlock(block) {
                // Start a new chunk: gather consecutive matching blocks
                let start = i
                var chunkBlocks: [TranscriptBlock] = []
                while i < blocks.count && filter.matchesBlock(blocks[i]) {
                    chunkBlocks.append(blocks[i])
                    i += 1
                }
                chunks.append(TranscriptChunk(
                    id: chunkId,
                    primaryKind: block.kind,
                    blocks: chunkBlocks,
                    sourceRange: start..<i
                ))
                chunkId += 1
            } else {
                i += 1
            }
        }
        return chunks
    }

    // MARK: - Chunk View

    @ViewBuilder
    private func transcriptChunkView(_ chunk: TranscriptChunk, allBlocks: [TranscriptBlock]) -> some View {
        let isExpanded = expandedChunkIndex == chunk.id
        let isUserChunk = chunk.primaryKind == .userMessage
        let chunkColor = isUserChunk ? DesignSystem.Colors.whimsy : accentColor

        VStack(alignment: .leading, spacing: 0) {
            // Chunk button
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedChunkIndex = isExpanded ? nil : chunk.id
                }
            } label: {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Group {
                        if isUserChunk {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(chunkColor)
                                .frame(width: 20, height: 20)
                                .background(chunkColor.opacity(0.12))
                                .clipShape(Circle())
                        } else {
                            assistantAvatarBadge(size: 20)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Text(isUserChunk ? "You" : "Assistant")
                                .font(DesignSystem.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(chunkColor)
                            if chunk.blockCount > 1 {
                                Text("\(chunk.blockCount) messages")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer()
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        if !isExpanded {
                            Text(chunk.preview)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSystem.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content: show the chunk's blocks + surrounding context
            if isExpanded {
                Divider()
                    .background(chunkColor.opacity(0.2))
                    .padding(.horizontal, DesignSystem.Spacing.md)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    // Show a few blocks before for context
                    let contextBefore = contextBlocksBefore(chunk.sourceRange.lowerBound, in: allBlocks)
                    if !contextBefore.isEmpty {
                        ForEach(Array(contextBefore.enumerated()), id: \.offset) { _, block in
                            transcriptBlock(block)
                                .opacity(0.5)
                        }
                        Divider()
                            .background(chunkColor.opacity(0.15))
                    }

                    // The actual chunk blocks
                    ForEach(Array(chunk.blocks.enumerated()), id: \.offset) { _, block in
                        transcriptBlock(block)
                    }

                    // Show a few blocks after for context
                    let contextAfter = contextBlocksAfter(chunk.sourceRange.upperBound, in: allBlocks)
                    if !contextAfter.isEmpty {
                        Divider()
                            .background(chunkColor.opacity(0.15))
                        ForEach(Array(contextAfter.enumerated()), id: \.offset) { _, block in
                            transcriptBlock(block)
                                .opacity(0.5)
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(chunkColor.opacity(isExpanded ? 0.04 : 0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(chunkColor.opacity(isExpanded ? 0.2 : 0.12), lineWidth: 0.5)
        }
    }

    /// Grabs up to 2 context blocks before the chunk for expanded view.
    private func contextBlocksBefore(_ index: Int, in blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        let start = max(0, index - 2)
        guard start < index else { return [] }
        return Array(blocks[start..<index]).filter { $0.kind != .separator }
    }

    /// Grabs up to 2 context blocks after the chunk for expanded view.
    private func contextBlocksAfter(_ index: Int, in blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        let end = min(blocks.count, index + 2)
        guard index < end else { return [] }
        return Array(blocks[index..<end]).filter { $0.kind != .separator }
    }

    private var transcriptMetadataCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                metadataField(label: "Provider", value: record.provider.displayName, color: DesignSystem.Colors.primary(for: record.provider))
                metadataField(label: "Project", value: record.projectName, color: DesignSystem.Colors.textPrimary)
            }
            HStack(spacing: DesignSystem.Spacing.md) {
                if let start = record.startTime {
                    metadataField(label: "Started", value: durationLabel(for: start), color: DesignSystem.Colors.textSecondary)
                }
                if let end = record.endTime {
                    metadataField(label: "Ended", value: durationLabel(for: end), color: DesignSystem.Colors.textSecondary)
                }
                if let start = record.startTime, let end = record.endTime {
                    let dur = end.timeIntervalSince(start)
                    if dur > 60 {
                        metadataField(label: "Duration", value: durationLabel(dur), color: DesignSystem.Colors.textSecondary)
                    }
                }
            }
            HStack(spacing: DesignSystem.Spacing.md) {
                metadataField(label: "Messages", value: "\(record.messageCount)", color: DesignSystem.Colors.textSecondary)
                if record.userWordCount > 0 || record.assistantWordCount > 0 {
                    metadataField(label: "Words", value: "\(record.userWordCount + record.assistantWordCount)", color: DesignSystem.Colors.textSecondary)
                }
            }
            if !record.keyTools.isEmpty {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("Tools")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    ForEach(record.keyTools.prefix(6), id: \.self) { tool in
                        Text(tool)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.whimsy.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
            if !record.keyFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key Files")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    ForEach(record.keyFiles.prefix(4), id: \.self) { file in
                        Text(abbreviatePath(file))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func metadataField(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(color)
        }
        .frame(minWidth: 80, alignment: .leading)
    }

    private func transcriptSummaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                Text("Summary")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Text(summary)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.amber.opacity(0.06))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.amber.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func transcriptBlock(_ block: TranscriptBlock) -> some View {
        switch block.kind {
        case .userMessage:
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                    .frame(width: 20, height: 20)
                    .background(DesignSystem.Colors.whimsy.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("You")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.whimsy)
                    Text(.init(block.content))
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 4,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
                .fill(DesignSystem.Colors.whimsy.opacity(0.06))
            }
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 4,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
                .strokeBorder(DesignSystem.Colors.whimsy.opacity(0.2), lineWidth: 0.5)
            )

        case .assistantMessage:
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                assistantAvatarBadge(size: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(accentColor)
                    Text(.init(block.content))
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 4,
                    style: .continuous
                )
                .fill(DesignSystem.Colors.surface.opacity(0.6))
            }
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 4,
                    style: .continuous
                )
                .strokeBorder(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
            )

        case .toolUse:
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: toolIconForTranscript(block.label ?? block.content))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.coral)
                Text(block.label ?? "Tool")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.coral)
                if !block.content.isEmpty && block.content != (block.label ?? "") {
                    Text(block.content)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background {
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.coral.opacity(0.08))
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DesignSystem.Colors.coral.opacity(0.2), lineWidth: 0.5)
            )

        case .codeBlock:
            VStack(alignment: .leading, spacing: 0) {
                if let lang = block.label, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xxs)
                        .background(DesignSystem.Colors.border.opacity(0.3))
                }
                Text(block.content)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DesignSystem.Colors.background.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
            )

        case .separator:
            Divider()
                .background(DesignSystem.Colors.border.opacity(0.3))
                .padding(.vertical, DesignSystem.Spacing.xs)
        }
    }

    private func toolIconForTranscript(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("read") || n.contains("file") || n.contains("write") { return "doc.text" }
        if n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") { return "magnifyingglass" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") { return "globe" }
        if n.contains("edit") || n.contains("patch") { return "pencil.and.outline" }
        if n.contains("agent") { return "person.2" }
        if n.contains("task") { return "checklist" }
        return "wrench.and.screwdriver"
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = path
        if p.hasPrefix(home) {
            p = "~" + p.dropFirst(home.count)
        }
        return p
    }

    private func durationLabel(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    @ViewBuilder
    private func jumpTargetCard(_ target: ConversationJumpTarget) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                Text(target.source == .aggregateExact ? "Exact transcript match" : "Retrieved passage")
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(DesignSystem.Colors.whimsy)

            Text(target.snippet)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)

            Text("Offsets \(target.startOffset)-\(target.endOffset)")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.whimsy.opacity(0.08))
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if record.sourceType == .cliAssistant {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 9, weight: .semibold))
                    } else {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    Text(record.sourceType == .cliAssistant ? "Assistant" : record.provider.displayName)
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xxs)
                .background(
                    Capsule().fill(accentColor.opacity(0.14))
                )
                .overlay(
                    Capsule().strokeBorder(accentColor.opacity(0.35), lineWidth: 0.5)
                )

                Text(record.projectName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer(minLength: 0)

                if let date = record.endTime ?? record.startTime {
                    Text(date.relativeLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(displayTitle)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                metaChip(icon: "bubble.left.and.bubble.right", label: "\(record.messageCount) messages")
                if record.userWordCount > 0 {
                    metaChip(icon: "textformat", label: "\(record.userWordCount + record.assistantWordCount) words")
                }
                if record.sourceType == .providerLog, let start = record.startTime, let end = record.endTime {
                    let duration = end.timeIntervalSince(start)
                    if duration > 60 {
                        metaChip(icon: "clock", label: durationLabel(duration))
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .background(Color.clear)
    }

    private func metaChip(icon: String, label: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(DesignSystem.Colors.textMuted)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xxs)
        .background(
            Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
        )
        .overlay(
            Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var actionBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdownBody, forType: .string)
                withAnimation(DesignSystem.Animation.snappy) { copyConfirmed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(DesignSystem.Animation.snappy) { copyConfirmed = false }
                }
            } label: {
                Label(
                    copyConfirmed ? "Copied!" : "Copy Markdown",
                    systemImage: copyConfirmed ? "checkmark" : "doc.on.doc"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(copyConfirmed ? DesignSystem.Colors.success : accentColor)
            }
            .buttonStyle(.plain)
            .disabled(markdownBody.isEmpty)

            Button {
                exportMarkdown()
            } label: {
                Label("Export .md", systemImage: "arrow.down.doc")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(markdownBody.isEmpty)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    private func buildMarkdown() {
        if let body = overrideBody, !body.isEmpty {
            markdownBody = body
        } else {
            markdownBody = SessionLogMarkdownFormatter.markdown(for: record)
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        let slug = displayTitle.isEmpty ? "session" : displayTitle
        let safe = slug
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
            .prefix(60)
        panel.nameFieldStringValue = "\(safe).md"
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.title = "Export session log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdownBody.write(to: url, atomically: true, encoding: .utf8)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }
}

// MARK: - Date Relative Label

extension Date {
    var relativeLabel: String {
        let interval = Date().timeIntervalSince(self)
        switch interval {
        case ..<60:          return "Just now"
        case ..<3_600:       return "\(Int(interval / 60))m ago"
        case ..<86_400:      return "\(Int(interval / 3_600))h ago"
        case ..<604_800:     return "\(Int(interval / 86_400))d ago"
        default:
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return fmt.string(from: self)
        }
    }
}
