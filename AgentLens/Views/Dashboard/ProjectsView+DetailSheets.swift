import Charts
import OpenBurnBarCore
import SwiftUI

// Project-memory hero/page/visual detail sheets and citation insight sheet.
// Extracted from ProjectsView.swift (god-file decomposition) — same module, verbatim.

struct ProjectMemoryHeroDetailSheet: View {
    let snapshot: ProjectMemorySnapshot
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?
    @State private var selectedPage: ProjectMemoryPage?
    @State private var selectedVisual: ProjectMemoryVisual?
    @State private var citationWrapper: CitationWrapper?

    init(snapshot: ProjectMemorySnapshot, chatController: ChatSessionController) {
        self.snapshot = snapshot
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    WikiBreadcrumb(crumbs: [
                        WikiBreadcrumbItem(label: "Projects", action: { dismiss() }),
                        WikiBreadcrumbItem(label: snapshot.projectDisplayName, action: { dismiss() }),
                        WikiBreadcrumbItem(label: "Project memory", action: nil)
                    ])
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    EditorialHero(
                        eyebrow: "PROJECT MEMORY · \(snapshot.freshness.label)",
                        subtitle: subtitle,
                        headline: snapshot.projectDisplayName,
                        metaSegments: metaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: "Hermes is synthesizing the project memory into a three-beat brief: what the team is working on, where the spend is going, what to do next.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)

                    if !snapshot.pages.isEmpty {
                        pagesSection
                            .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !snapshot.visuals.isEmpty {
                        visualsSection
                            .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !snapshot.keyFiles.isEmpty {
                        keyFilesSection
                            .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !snapshot.keyCommands.isEmpty {
                        keyCommandsSection
                            .cascadeIn(index: 6, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    if !heroSeeAlsoItems.isEmpty {
                        WikiSeeAlsoRail(title: "Spider out", items: heroSeeAlsoItems, symbol: "point.3.connected.trianglepath.dotted")
                            .cascadeIn(index: 7, visible: visibleSections, reduceMotion: reduceMotion)
                    }

                    auditFooter
                        .cascadeIn(index: 8, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .sheet(item: $selectedPage) { page in
            ProjectMemoryPageDetailSheet(page: page, projectName: snapshot.projectDisplayName, chatController: chatController)
                .frame(minWidth: 720, minHeight: 540)
        }
        .sheet(item: $selectedVisual) { visual in
            ProjectMemoryVisualDetailSheet(visual: visual, chatController: chatController)
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(item: $citationWrapper) { wrapper in
            CitationInsightSheet(citations: wrapper.citations, chatController: chatController)
                .frame(minWidth: 800, minHeight: 620)
        }
    }

    private var chrome: some View {
        HStack {
            Text("Memory · \(snapshot.projectDisplayName)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button {
                handoffToChat()
            } label: {
                Label("Continue in chat", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let end = snapshot.sourceWindowEnd, let start = snapshot.sourceWindowStart {
            parts.append("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("Generated \(snapshot.generatedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    private var metaSegments: [String] {
        var parts: [String] = []
        parts.append("\(snapshot.sourceSessionCount) sessions")
        parts.append("\(snapshot.sourceConversationCount) transcripts")
        if let usage = parseUsageSummary() {
            parts.append(usage.cost)
            parts.append(usage.tokens)
        }
        parts.append("\(snapshot.keyFiles.count) files · \(snapshot.keyCommands.count) cmds")
        return parts
    }

    private var heroSeeAlsoItems: [WikiSeeAlsoItem] {
        var items: [WikiSeeAlsoItem] = []
        for page in snapshot.pages.prefix(3) {
            items.append(
                WikiSeeAlsoItem(
                    label: page.title,
                    detail: "\(page.sections.count) section\(page.sections.count == 1 ? "" : "s")",
                    symbol: "book.pages",
                    action: { selectedPage = page }
                )
            )
        }
        for visual in snapshot.visuals.prefix(3) {
            let detail: String = {
                switch visual.kind {
                case .cover:        return "cover"
                case .providerMix:  return "provider mix"
                case .timeline:     return "timeline"
                case .hotspots:     return "hotspots"
                }
            }()
            items.append(
                WikiSeeAlsoItem(
                    label: visual.title,
                    detail: detail,
                    symbol: "chart.bar",
                    action: { selectedVisual = visual }
                )
            )
        }
        let allCitations = snapshot.pages.flatMap { $0.sections.flatMap(\.citations) }
        if let firstCitation = allCitations.first {
            items.append(
                WikiSeeAlsoItem(
                    label: "Open \(allCitations.count) citation\(allCitations.count == 1 ? "" : "s") together",
                    detail: "synthesize evidence",
                    symbol: "quote.bubble",
                    action: { citationWrapper = CitationWrapper(citations: Array(allCitations.prefix(8))) }
                )
            )
            _ = firstCitation
        }
        return items
    }

    private func parseUsageSummary() -> (cost: String, tokens: String)? {
        let parts = snapshot.usageSummary.split(separator: " ")
        var cost: String?
        var tokens: String?
        for p in parts {
            if p.hasPrefix("$") { cost = String(p); continue }
            if p.contains("tok") || p.contains("M") || p.contains("B") || p.contains("K") {
                tokens = String(p)
            }
        }
        if let cost, let tokens { return (cost, tokens) }
        return nil
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("PAGES")
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(Array(snapshot.pages.enumerated()), id: \.element.id) { idx, page in
                    HeroPageRow(
                        ordinal: idx + 1,
                        total: snapshot.pages.count,
                        page: page,
                        onTap: { selectedPage = page },
                        onCitationTap: { c in citationWrapper = .single(c) }
                    )
                }
            }
        }
    }

    private var visualsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("VISUALS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ForEach(snapshot.visuals) { visual in
                        VisualTile(visual: visual, onTap: { selectedVisual = visual })
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var keyFilesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("KEY FILES")
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(snapshot.keyFiles.enumerated()), id: \.offset) { idx, file in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "%02d", idx + 1))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 24, alignment: .leading)
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(file)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    private var keyCommandsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("KEY COMMANDS")
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Array(snapshot.keyCommands.enumerated()), id: \.offset) { idx, cmd in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "%02d", idx + 1))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 24, alignment: .leading)
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(cmd)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("Schema v\(snapshot.schemaVersion)  ·  Hash \(String(snapshot.contentHash.prefix(8)))  ·  \(snapshot.freshness.label)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let prompt = """
        You are summarizing a local project memory snapshot for a developer.
        Write a tight three-paragraph brief — no preamble, no headings, no fluff.

        Paragraph 1: What the team is working on right now (use the pages + key files).
        Paragraph 2: Where the spend and effort are going (use the usage summary).
        Paragraph 3: What to do next (concrete, actionable, prioritized).

        Project: \(snapshot.projectDisplayName)
        Window: \(snapshot.usageSummary)
        Sessions: \(snapshot.sourceSessionCount); Transcripts: \(snapshot.sourceConversationCount)
        Key files: \(snapshot.keyFiles.prefix(8).joined(separator: ", "))
        Key commands: \(snapshot.keyCommands.prefix(6).joined(separator: " ; "))

        Page outlines:
        \(snapshot.pages.map { page in
            "• \(page.title) — \(page.summary)\n  sections: \(page.sections.map(\.title).joined(separator: ", "))"
        }.joined(separator: "\n"))
        """
        insight.generate(prompt: prompt)
    }

    @MainActor
    private func handoffToChat() {
        let prompt = """
        Continue analyzing the project memory for \(snapshot.projectDisplayName).
        Key files: \(snapshot.keyFiles.prefix(8).joined(separator: ", "))
        \(snapshot.usageSummary)
        Ask me what I want to dive into.
        """
        chatController.inputText = prompt
        Task { await chatController.send() }
        dismiss()
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 9
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<9 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}

struct HeroPageRow: View {
    let ordinal: Int
    let total: Int
    let page: ProjectMemoryPage
    let onTap: () -> Void
    let onCitationTap: (ProjectMemoryCitation) -> Void
    @State private var hovered = false

    private var aggregatedCitations: [ProjectMemoryCitation] {
        Array(page.sections.flatMap(\.citations).prefix(6))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text(String(format: "%02d", ordinal))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    Text(page.title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(ordinal) / \(total)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Text(page.summary)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !page.sections.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(page.sections) { section in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("·")
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                Text(section.title)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                }
                if !aggregatedCitations.isEmpty {
                    HFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Array(aggregatedCitations.prefix(5).enumerated()), id: \.element.id) { idx, c in
                            FootnoteCitationChip(
                                ordinal: idx + 1,
                                citation: c,
                                onTap: { onCitationTap(c) }
                            )
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open page")
                        .font(DesignSystem.Typography.monoTiny)
                        .tracking(0.8)
                }
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .padding(.top, 2)
            }
            .padding(.leading, DesignSystem.Spacing.md + 3 + DesignSystem.Spacing.sm)
            .padding(.trailing, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(hovered ? 0.85 : 0.55))
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(width: 3)
                    .padding(.leading, DesignSystem.Spacing.md)
                    .padding(.vertical, 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(
                        hovered ? DesignSystem.Colors.hermesAureate.opacity(0.45) : DesignSystem.Colors.border.opacity(0.3),
                        lineWidth: hovered ? 1 : 0.75
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.005 : 1.0)
        .animation(DesignSystem.Animation.hover, value: hovered)
        .onHover { hovered = $0 }
    }
}

struct VisualTile: View {
    let visual: ProjectMemoryVisual
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(visualKindLabel.uppercased())
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text(visual.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                if let subtitle = visual.subtitle {
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
                MiniVisualPreview(visual: visual)
                    .frame(height: 60)
                Text("\(visual.points.count) points · open →")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(width: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(hovered ? 0.85 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: hovered ? 1 : 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.02 : 1.0)
        .animation(DesignSystem.Animation.hover, value: hovered)
        .onHover { hovered = $0 }
    }

    private var visualKindLabel: String {
        switch visual.kind {
        case .cover: return "Cover"
        case .providerMix: return "Provider Mix"
        case .timeline: return "Timeline"
        case .hotspots: return "Hotspots"
        }
    }
}

struct MiniVisualPreview: View {
    let visual: ProjectMemoryVisual

    var body: some View {
        Chart {
            switch visual.kind {
            case .timeline:
                ForEach(Array(visual.points.enumerated()), id: \.offset) { idx, p in
                    LineMark(x: .value("i", idx), y: .value("v", p.value))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .interpolationMethod(.catmullRom)
                }
            default:
                ForEach(Array(visual.points.prefix(6).enumerated()), id: \.offset) { idx, p in
                    BarMark(x: .value("i", idx), y: .value("v", p.value))
                        .foregroundStyle(barColor(idx))
                        .cornerRadius(2)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }

    private func barColor(_ idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.amber,
            DesignSystem.Colors.hermesMercury
        ]
        return palette[idx % palette.count]
    }
}

struct ProjectMemoryPageDetailSheet: View {
    let page: ProjectMemoryPage
    let projectName: String
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?
    @State private var citationWrapper: CitationWrapper?

    init(page: ProjectMemoryPage, projectName: String, chatController: ChatSessionController) {
        self.page = page
        self.projectName = projectName
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                        WikiBreadcrumb(crumbs: breadcrumbs)
                            .id("__top")
                            .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                        EditorialHero(
                            eyebrow: "MEMORY PAGE · \(page.title)",
                            subtitle: page.summary,
                            headline: page.title,
                            metaSegments: heroMetaSegments,
                            leadAccent: DesignSystem.Colors.hermesAureate
                        )
                        .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                        HermesReadingCard(
                            title: "Hermes Reading",
                            placeholder: "Hermes is interpreting this page — what it tells the operator and what to do with it.",
                            controller: insight,
                            onRetry: { startInsight() }
                        )
                        .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)

                        if page.sections.count > 1 {
                            WikiTableOfContents(items: tocItems) { anchor in
                                withAnimation(DesignSystem.Animation.gentle) {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            }
                            .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)
                        }

                        if !page.sections.isEmpty {
                            sectionsSection
                                .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
                        } else {
                            EmptyEvidenceCallout(message: "This page has no synthesized sections yet.")
                                .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)
                        }

                        if !seeAlsoItems.isEmpty {
                            WikiSeeAlsoRail(title: "See also", items: seeAlsoItems, symbol: "link")
                                .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)
                        }

                        if !page.visualIDs.isEmpty {
                            visualsRefsSection
                                .cascadeIn(index: 6, visible: visibleSections, reduceMotion: reduceMotion)
                        }

                        auditFooter
                            .cascadeIn(index: 7, visible: visibleSections, reduceMotion: reduceMotion)
                    }
                    .padding(DesignSystem.Spacing.xl)
                }
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .sheet(item: $citationWrapper) { wrapper in
            CitationInsightSheet(citations: wrapper.citations, chatController: chatController)
                .frame(minWidth: 800, minHeight: 620)
        }
    }

    private var breadcrumbs: [WikiBreadcrumbItem] {
        [
            WikiBreadcrumbItem(label: projectName, action: { dismiss() }),
            WikiBreadcrumbItem(label: "Project memory", action: { dismiss() }),
            WikiBreadcrumbItem(label: page.title, action: nil)
        ]
    }

    private var tocItems: [WikiTOCItem] {
        page.sections.enumerated().map { idx, section in
            WikiTOCItem(
                id: sectionAnchorID(section),
                ordinal: idx + 1,
                title: section.title,
                citationCount: section.citations.count,
                body: section.body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .first ?? ""
            )
        }
    }

    private var seeAlsoItems: [WikiSeeAlsoItem] {
        var items: [WikiSeeAlsoItem] = []
        let allCitations = page.sections.flatMap(\.citations)
        let topCitations = Array(allCitations.prefix(3))
        for c in topCitations {
            let detail: String
            switch c.sourceKind {
            case .conversation:    detail = "transcript"
            case .skillDoc:        detail = "skill doc"
            case .agentDoc:        detail = "agent doc"
            case .sharedArtifact:  detail = "shared artifact"
            }
            items.append(
                WikiSeeAlsoItem(
                    label: c.title.isEmpty ? "Untitled" : c.title,
                    detail: detail,
                    symbol: "quote.bubble",
                    action: { citationWrapper = .single(c) }
                )
            )
        }
        if !page.visualIDs.isEmpty {
            items.append(
                WikiSeeAlsoItem(
                    label: "\(page.visualIDs.count) referenced visual\(page.visualIDs.count == 1 ? "" : "s")",
                    detail: "in this snapshot",
                    symbol: "chart.bar",
                    action: { handoffToChat() }
                )
            )
        }
        return items
    }

    private func sectionAnchorID(_ section: ProjectMemorySection) -> String {
        "section-\(section.id)"
    }

    private var chrome: some View {
        HStack {
            Text("\(projectName) · Memory page")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button {
                handoffToChat()
            } label: {
                Label("Deep dive in chat", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var heroMetaSegments: [String] {
        var parts: [String] = []
        parts.append("\(page.sections.count) sections")
        let totalCitations = page.sections.reduce(0) { $0 + $1.citations.count }
        parts.append("\(totalCitations) citations")
        if !page.visualIDs.isEmpty {
            parts.append("\(page.visualIDs.count) visuals")
        }
        return parts
    }

    private var sectionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("SECTIONS")
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(Array(page.sections.enumerated()), id: \.element.id) { idx, section in
                    NumberedSectionRow(
                        index: idx + 1,
                        total: page.sections.count,
                        title: section.title,
                        text: section.body,
                        accent: accentColor(for: idx),
                        citations: section.citations,
                        onCitationTap: { c in citationWrapper = .single(c) },
                        onCombinedCitationTap: section.citations.isEmpty ? nil : {
                            citationWrapper = CitationWrapper(citations: section.citations)
                        },
                        pivotQueries: WikiQuery.curated(forSectionTitle: section.title, projectName: projectName),
                        onPivotTap: { query in runPivot(query) }
                    )
                    .id(sectionAnchorID(section))
                }
            }
        }
    }

    private func runPivot(_ query: WikiQuery) {
        chatController.inputText = query.prompt
        Task { await chatController.send() }
        dismiss()
    }

    private var visualsRefsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("REFERENCED VISUALS")
            Text(page.visualIDs.joined(separator: " · "))
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.4))
                )
        }
    }

    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            Text("page-id \(page.id)  ·  \(page.sections.count) sections  ·  \(page.visualIDs.count) visuals")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func accentColor(for idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.amber
        ]
        return palette[idx % palette.count]
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let prompt = """
        You are reading a single page from a project memory snapshot. Write a tight 2–3 paragraph reading — no preamble, no headings, no fluff.

        Paragraph 1: What this page is actually saying about the project right now (synthesize across the sections).
        Paragraph 2: What gaps, risks, or questions the operator should care about (be specific, name files or session ids when relevant).
        Paragraph 3 (optional): What next move makes sense — a concrete suggestion the operator can take in the next 30 minutes.

        Project: \(projectName)
        Page: \(page.title)
        Summary: \(page.summary)

        Sections:
        \(page.sections.map { section in
            "• \(section.title)\n  \(section.body)"
        }.joined(separator: "\n\n"))
        """
        insight.generate(prompt: prompt)
    }

    @MainActor
    private func handoffToChat() {
        let prompt = """
        Deep dive into the project memory page "\(page.title)" for \(projectName).
        Summary: \(page.summary)
        Sections to analyze: \(page.sections.map(\.title).joined(separator: ", "))
        Pull on threads from the body text, surface contradictions, and suggest next investigations.
        """
        chatController.inputText = prompt
        Task { await chatController.send() }
        dismiss()
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 8
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<8 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}

struct ProjectMemoryVisualDetailSheet: View {
    let visual: ProjectMemoryVisual
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?
    @State private var sortAscending: Bool = false

    init(visual: ProjectMemoryVisual, chatController: ChatSessionController) {
        self.visual = visual
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    WikiBreadcrumb(crumbs: [
                        WikiBreadcrumbItem(label: "Project memory", action: { dismiss() }),
                        WikiBreadcrumbItem(label: "Visuals", action: { dismiss() }),
                        WikiBreadcrumbItem(label: visual.title, action: nil)
                    ])
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    EditorialHero(
                        eyebrow: "VISUAL · \(kindLabel.uppercased())",
                        subtitle: visual.subtitle ?? "Source: local project memory snapshot.",
                        headline: visual.title,
                        metaSegments: heroMetaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    WikiPivotPillRow(
                        queries: WikiQuery.curatedForVisual(visual, projectName: "this project"),
                        onTap: { runPivot($0) }
                    )
                    .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)

                    chartCard
                        .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)

                    dataTableSection
                        .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: "Hermes is interpreting this visual — what the distribution implies and what to do about it.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)

                    auditFooter
                        .cascadeIn(index: 6, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
    }

    @MainActor
    private func runPivot(_ query: WikiQuery) {
        chatController.inputText = query.prompt
        Task { await chatController.send() }
        dismiss()
    }

    private var chrome: some View {
        HStack {
            Text("Visual · \(kindLabel)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button {
                sortAscending.toggle()
            } label: {
                Label(sortAscending ? "Sort: ascending" : "Sort: descending",
                      systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var kindLabel: String {
        switch visual.kind {
        case .cover: return "Cover"
        case .providerMix: return "Provider Mix"
        case .timeline: return "Timeline"
        case .hotspots: return "Hotspots"
        }
    }

    private var heroMetaSegments: [String] {
        var parts: [String] = []
        parts.append("\(visual.points.count) points")
        let sum = visual.points.reduce(0.0) { $0 + $1.value }
        if visual.kind == .providerMix {
            parts.append("Σ \(sum.formatAsCost())")
        } else if visual.kind == .timeline {
            parts.append("Σ \(Int(sum).formatAsTokenVolume())")
        } else {
            parts.append("Σ \(Int(sum))")
        }
        if let mx = visual.points.max(by: { $0.value < $1.value }) {
            parts.append("max · \(mx.label)")
        }
        return parts
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("DISTRIBUTION")
            VisualChart(visual: visual, sortAscending: sortAscending)
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
                )
        }
    }

    private var sortedPoints: [ProjectMemoryVisualPoint] {
        visual.points.sorted {
            sortAscending ? $0.value < $1.value : $0.value > $1.value
        }
    }

    private var hasDetail: Bool {
        sortedPoints.contains { $0.subtitle != nil }
    }

    private var dataTableSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("DATA POINTS")
            VStack(spacing: 0) {
                HStack {
                    Text("LABEL")
                        .font(DesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("VALUE")
                        .font(DesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 120, alignment: .trailing)
                    if hasDetail {
                        Text("DETAIL")
                            .font(DesignSystem.Typography.monoTiny)
                            .tracking(1.4)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 140, alignment: .trailing)
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.sm)
                Rectangle()
                    .fill(DesignSystem.Colors.border.opacity(0.5))
                    .frame(height: 0.5)

                ForEach(Array(sortedPoints.enumerated()), id: \.offset) { _, point in
                    HStack {
                        Text(point.label)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(valueLabel(point))
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .frame(width: 120, alignment: .trailing)
                        if hasDetail {
                            if let subtitle = point.subtitle {
                                Text(subtitle)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .frame(width: 140, alignment: .trailing)
                            } else {
                                Color.clear.frame(width: 140)
                            }
                        }
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    Rectangle()
                        .fill(DesignSystem.Colors.border.opacity(0.25))
                        .frame(height: 0.5)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    private var auditFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            Text("visual-id \(visual.id)  ·  kind \(visual.kind.rawValue)  ·  \(visual.points.count) points")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func valueLabel(_ point: ProjectMemoryVisualPoint) -> String {
        if let s = point.subtitle, !s.isEmpty { return s }
        if visual.kind == .providerMix { return point.value.formatAsCost() }
        if visual.kind == .timeline { return Int(point.value).formatAsTokenVolume() }
        return String(Int(point.value))
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let topLine = sortedPoints.prefix(5).map { p in
            "\(p.label): \(valueLabel(p))"
        }.joined(separator: " · ")
        let prompt = """
        You are reading a chart from a project memory snapshot.

        Write a tight 2-paragraph reading — no preamble, no headings, no fluff.

        Paragraph 1: What the distribution means (concentration, skew, outliers, recent shifts).
        Paragraph 2: What action the developer should take — concrete, specific, with at most one number.

        Visual: \(visual.title) (kind: \(kindLabel))
        Subtitle: \(visual.subtitle ?? "—")
        Top points: \(topLine)
        Total points: \(visual.points.count)
        """
        insight.generate(prompt: prompt)
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 7
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<7 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }
}

struct CitationInsightSheet: View {
    let citations: [ProjectMemoryCitation]
    let chatController: ChatSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insight: ProjectMemoryInsightController
    @State private var visibleSections: Int = -1
    @State private var cascadeTask: Task<Void, Never>?

    init(citations: [ProjectMemoryCitation], chatController: ChatSessionController) {
        self.citations = citations
        self.chatController = chatController
        _insight = State(initialValue: ProjectMemoryInsightController(chatController: chatController))
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    WikiBreadcrumb(crumbs: [
                        WikiBreadcrumbItem(label: "Project memory", action: { dismiss() }),
                        WikiBreadcrumbItem(label: "Citations", action: { dismiss() }),
                        WikiBreadcrumbItem(label: citations.count == 1 ? (citations.first?.title ?? "Citation") : "\(citations.count) citations", action: nil)
                    ])
                    .cascadeIn(index: 0, visible: visibleSections, reduceMotion: reduceMotion)

                    EditorialHero(
                        eyebrow: "CITATION INSIGHT · \(citations.count) CITATION\(citations.count == 1 ? "" : "S")",
                        subtitle: heroSubtitle,
                        headline: heroHeadline,
                        metaSegments: heroMetaSegments,
                        leadAccent: DesignSystem.Colors.hermesAureate
                    )
                    .cascadeIn(index: 1, visible: visibleSections, reduceMotion: reduceMotion)

                    WikiPivotPillRow(
                        queries: WikiQuery.curatedForCitations(citations),
                        onTap: { runPivot($0) }
                    )
                    .cascadeIn(index: 2, visible: visibleSections, reduceMotion: reduceMotion)

                    HermesReadingCard(
                        title: "Hermes Reading",
                        placeholder: citations.count == 1
                            ? "Hermes is reading this citation — what it means and why it matters."
                            : "Hermes is reading the evidence — drawing connections and surfacing what matters.",
                        controller: insight,
                        onRetry: { startInsight() }
                    )
                    .cascadeIn(index: 3, visible: visibleSections, reduceMotion: reduceMotion)

                    evidenceSection
                        .cascadeIn(index: 4, visible: visibleSections, reduceMotion: reduceMotion)

                    handoffFooter
                        .cascadeIn(index: 5, visible: visibleSections, reduceMotion: reduceMotion)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { startInsight(); runEntranceMotion() }
        .onDisappear { cascadeTask?.cancel(); insight.cancel() }
        .onChange(of: chatController.streamingTick) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
        .onChange(of: chatController.isStreaming) { _, _ in
            insight.observeStreamingTick(
                messages: chatController.messages,
                activeID: chatController.activeStreamMessageId,
                isStreaming: chatController.isStreaming
            )
        }
    }

    private var chrome: some View {
        HStack {
            Text("Citation insight · live")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private var heroHeadline: String {
        if citations.count == 1, let only = citations.first {
            return only.title.isEmpty ? "Untitled evidence" : only.title
        }
        let trimmed = insight.streamingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let dot = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            return String(trimmed[..<dot]) + "."
        }
        return "Reading the evidence"
    }

    private var heroSubtitle: String {
        let kinds = Array(Set(citations.map(\.sourceKind))).map { kind -> String in
            switch kind {
            case .conversation:    return "transcripts"
            case .skillDoc:        return "skill docs"
            case .agentDoc:        return "agent docs"
            case .sharedArtifact:  return "shared artifacts"
            }
        }
        return "Across " + kinds.joined(separator: ", ") + " · synthesized by Hermes"
    }

    private var heroMetaSegments: [String] {
        var parts: [String] = []
        parts.append("\(citations.count) cite\(citations.count == 1 ? "" : "s")")
        let snippetChars = citations.reduce(0) { $0 + $1.snippet.count }
        parts.append("\(snippetChars) chars evidence")
        if let oldest = citations.compactMap(\.createdAt).min() {
            parts.append("since \(oldest.formatted(.relative(presentation: .named)))")
        }
        return parts
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionEyebrow("EVIDENCE")
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { idx, citation in
                    CitationQuoteCard(ordinal: idx + 1, citation: citation)
                }
            }
        }
    }

    private var handoffFooter: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Rectangle()
                .fill(DesignSystem.Colors.mercuryGradient)
                .frame(height: 0.5)
            HStack {
                Text("Want to keep pulling on this thread?")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    handoffToChat()
                } label: {
                    Label("Continue in chat", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .tracking(2.0)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func startInsight() {
        let citationSummaries = citations.enumerated().map { idx, citation in
            """
            [\(String(format: "%02d", idx + 1))] \(citation.title) (\(citation.sourceKind.rawValue), id: \(citation.sourceID))
            \(citation.snippet)
            """
        }.joined(separator: "\n\n")

        let prompt = citations.count == 1 ? """
            You are reading a single piece of evidence from a project's local memory. Write a tight 2-paragraph reading — no preamble, no headings, no fluff.

            Paragraph 1: What this evidence actually says and why it matters in this project.
            Paragraph 2: What the operator should do next — concrete, specific, low-friction.

            \(citationSummaries)
            """ : """
            You are synthesizing a small evidence pack from a project's local memory. The citations below were grouped because they share a section. Write a tight 2–3 paragraph reading — no preamble, no headings, no fluff. Connect across the citations.

            Paragraph 1: What story this evidence tells, drawing connections (name 1–2 citations by their [01]-style ordinals).
            Paragraph 2: What pattern or risk this surfaces.
            Paragraph 3 (optional): What concrete next move makes sense given this evidence.

            \(citationSummaries)
            """
        insight.generate(prompt: prompt)
    }

    @MainActor
    private func handoffToChat() {
        let citationTitles = citations.prefix(5).map(\.title).joined(separator: ", ")
        let prompt = """
        Continue analyzing these citations — pull on the threads I haven't surfaced yet.
        Citations: \(citationTitles)
        Hermes already gave me one reading — give me a deeper one with concrete file/path mentions if you can.
        """
        chatController.inputText = prompt
        Task { await chatController.send() }
        dismiss()
    }

    private func runEntranceMotion() {
        if reduceMotion {
            visibleSections = 6
            return
        }
        guard visibleSections < 0 else { return }
        visibleSections = 0
        cascadeTask?.cancel()
        cascadeTask = Task { @MainActor in
            for i in 0..<6 {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    if Task.isCancelled { return }
                }
                withAnimation(DesignSystem.Animation.gentle) {
                    visibleSections = i + 1
                }
            }
        }
    }

    @MainActor
    private func runPivot(_ query: WikiQuery) {
        chatController.inputText = query.prompt
        Task { await chatController.send() }
        dismiss()
    }
}
