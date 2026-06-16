import SwiftUI

// Atlas refresh key, corpus row, search-source helpers, and small band/bar subviews.
// Extracted from DatabaseWorkspaceView.swift (god-file decomposition) — same module, verbatim.

struct AtlasRefreshKey: Equatable {
    let mode: DatabaseWorkspaceMode
    let filter: DatabaseWorkspaceFilterState
    let contentVersion: String
}

struct AtlasCorpusRow: Identifiable, Equatable {
    let id: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let providerLabel: String
    let projectName: String?
    let title: String
    let subtitle: String?
    let preview: String
    let displayDate: Date
    let indexedAt: Date
    let selection: DatabaseWorkspaceSelection

    init(retrievalResult: RetrievalResult) {
        id = retrievalResult.id
        sourceKind = retrievalResult.sourceKind
        sourceID = retrievalResult.sourceID
        providerLabel = retrievalResult.provider?.displayName
            ?? retrievalResult.providerRawValue
            ?? "—"
        projectName = retrievalResult.projectName
        title = retrievalResult.title
        subtitle = AtlasCorpusRow.cleanText(retrievalResult.subtitle)
        preview = AtlasCorpusRow.cleanText(retrievalResult.snippet)
        displayDate = retrievalResult.sourceUpdatedAt ?? retrievalResult.indexedAt
        indexedAt = retrievalResult.indexedAt
        selection = .indexedDocument(retrievalResult.documentID)
    }

    init(document: SearchDocumentRecord) {
        id = document.id
        sourceKind = document.sourceKind
        sourceID = document.sourceID
        providerLabel = document.provider.flatMap(AgentProvider.init(rawValue:))?.displayName
            ?? document.provider
            ?? "—"
        projectName = document.projectName
        title = document.title
        subtitle = AtlasCorpusRow.cleanText(document.subtitle)
        preview = AtlasCorpusRow.cleanText(document.bodyPreview)
        displayDate = document.sourceUpdatedAt ?? document.indexedAt
        indexedAt = document.indexedAt
        selection = .indexedDocument(document.id)
    }

    static func cleanText(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SearchSourceKind {
    var databaseDisplayName: String {
        switch self {
        case .conversation:
            return "Conversation"
        case .skillDoc:
            return "Skill"
        case .agentDoc:
            return "Agent Doc"
        case .sharedArtifact:
            return "Shared"
        case .code:
            return "Code"
        }
    }
}

struct WideBand<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(title)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), DesignSystem.Colors.border.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}

struct BarFill: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DesignSystem.Colors.borderSubtle)
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(fraction, 1))), height: 6)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
    }
}

struct StoryRevealModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(DesignSystem.Animation.standard.delay(delay), value: appeared)
    }
}

extension View {
    func storyReveal(appeared: Bool, delay: Double) -> some View {
        modifier(StoryRevealModifier(appeared: appeared, delay: delay))
    }
}
