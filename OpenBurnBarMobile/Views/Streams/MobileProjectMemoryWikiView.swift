import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Mobile Project Memory Wiki View
//
// A premium, interactive Wiki Brief explorer for project memory snapshots.
// Features editorial layouts, animated breathing AI orbs, expandable sections,
// interactive charts, and a citational Evidence Library.
//
struct MobileProjectMemoryWikiView: View {
    let project: ProjectSummary
    let memory: MobileProjectMemorySnapshot
    let store: ProjectsStore
    @Binding var selectedSession: TokenUsage?

    // Animations
    @State private var isBreathing = false
    @State private var isOrbRotating = false

    // Interactions
    @State private var expandedSections: Set<String> = ["recent-work"]
    @State private var selectedVisualPointLabel: String?
    @State private var evidenceSearchText = ""
    @State private var evidenceFilterModel: String?

    private var allSessions: [TokenUsage] {
        store.sessions(for: project)
    }

    private var filteredSessions: [TokenUsage] {
        allSessions.filter { session in
            let matchesSearch = evidenceSearchText.isEmpty ||
                session.model.localizedCaseInsensitiveContains(evidenceSearchText) ||
                session.provider.rawValue.localizedCaseInsensitiveContains(evidenceSearchText)
            let matchesModel = evidenceFilterModel == nil || session.model == evidenceFilterModel
            return matchesSearch && matchesModel
        }
    }

    private var uniqueModels: [String] {
        Array(Set(allSessions.map(\.model))).sorted()
    }

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            // 1. Editorial Header & freshness banner
            editorialHeader

            // 2. Hermes Reading Narrative Brief with animated breathing orb
            hermesNarrativeCard

            // 3. Expandable wiki pages (sections) with citations
            wikiSectionsList

            // 4. Interactive Visual Metrics Shelf
            interactiveVisualsShelf

            // 5. Backing Evidence Library
            evidenceLibraryShelf
        }
        .onAppear {
            // Trigger SOTA smooth breathing animations
            withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
            withAnimation(.linear(duration: 20.0).repeatForever(autoreverses: false)) {
                isOrbRotating = true
            }
        }
    }

    // MARK: - Subviews

    private var editorialHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("PROJECT MEMORY WIKI")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.5)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [MobileTheme.hermesAureate, MobileTheme.ember],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Spacer()

                // Freshness Indicator
                HStack(spacing: 5) {
                    Circle()
                        .fill(freshnessColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: freshnessColor.opacity(0.8), radius: 3)
                    Text(memory.freshnessLabel.uppercased())
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(MobileTheme.Colors.surfaceElevated)
                        .overlay(
                            Capsule()
                                .stroke(MobileTheme.Colors.border.opacity(0.3), lineWidth: 0.5)
                        )
                )
            }

            Text(project.projectName)
                .font(MobileTheme.Typography.title)
                .fontWeight(.bold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            Text("Aggregated across \(memory.sourceSessionCount) active sessions · Generated \(memory.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.top, 4)
    }

    private var hermesNarrativeCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 20) {
            ZStack(alignment: .topTrailing) {
                // Background Decorative Subtle Breathing Orb (SOTA luxury aesthetic)
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    MobileTheme.hermesAureate.opacity(isBreathing ? 0.24 : 0.08),
                                    MobileTheme.ember.opacity(isBreathing ? 0.12 : 0.02),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .scaleEffect(isBreathing ? 1.25 : 0.85)
                        .blur(radius: 20)
                        .rotationEffect(.degrees(isOrbRotating ? 360 : 0))

                    // Visual Core "Pulse" Orb
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [MobileTheme.hermesAureate, MobileTheme.ember, MobileTheme.whimsy, MobileTheme.hermesAureate],
                                center: .center
                            ),
                            lineWidth: 1.5
                        )
                        .background(Circle().fill(MobileTheme.Colors.surface.opacity(0.4)))
                        .frame(width: 24, height: 24)
                        .shadow(color: MobileTheme.hermesAureate.opacity(0.6), radius: 8)
                        .scaleEffect(isBreathing ? 1.15 : 0.9)
                        .offset(x: 70, y: -40)
                }
                .alignmentGuide(.top) { d in d[.top] + 20 }
                .alignmentGuide(.trailing) { d in d[.trailing] - 20 }
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [MobileTheme.hermesAureate, MobileTheme.ember],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("Hermes Synthesis")
                            .font(MobileTheme.Typography.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }

                    Text("This wiki brief compiles recent active context snapshots from your background agents. Hermes has summarized active workflows and localized spikes below.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    // Highlights metrics
                    HStack(spacing: 16) {
                        metricCapsule(title: "TOTAL BURN", value: memory.sourceCostTotal.formatAsCost(), color: MobileTheme.ember)
                        metricCapsule(title: "TOKENS", value: memory.sourceTokenTotal.formatAsTokenVolume(), color: MobileTheme.hermesAureate)
                        metricCapsule(title: "EVIDENCE", value: "\(memory.sourceSessionCount) logs", color: MobileTheme.whimsy)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var wikiSectionsList: some View {
        VStack(spacing: 12) {
            ForEach(memory.sections, id: \.id) { section in
                let isExpanded = expandedSections.contains(section.id)
                VStack(alignment: .leading, spacing: 0) {
                    // Header (toggable)
                    Button {
                        HapticBus.send()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            if isExpanded {
                                expandedSections.remove(section.id)
                            } else {
                                expandedSections.insert(section.id)
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(MobileTheme.Typography.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                if !isExpanded {
                                    Text(section.body.components(separatedBy: "\n").first ?? "")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 14) {
                            MercuryDivider().opacity(0.3)

                            // Body list parsing markdown-ish lines
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(section.body.components(separatedBy: "\n"), id: \.self) { line in
                                    if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle()
                                                .fill(MobileTheme.hermesAureate.opacity(0.8))
                                                .frame(width: 5, height: 5)
                                                .offset(y: 6)
                                            Text(line)
                                                .font(MobileTheme.Typography.caption)
                                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                                .lineSpacing(3)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }

                            // Interactive Citations Shelf
                            if !section.citations.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Citations")
                                        .font(MobileTheme.Typography.tiny)
                                        .fontWeight(.bold)
                                        .tracking(1.2)
                                        .foregroundStyle(MobileTheme.hermesAureate)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(section.citations) { citation in
                                                Button {
                                                    navigateToCitation(citation)
                                                } label: {
                                                    HStack(spacing: 6) {
                                                        Image(systemName: "doc.text.fill")
                                                            .font(MobileTheme.Typography.caption)
                                                        Text(citation.model)
                                                            .fontWeight(.semibold)
                                                        Text("·")
                                                        Text(citation.observedAt, style: .relative)
                                                            .foregroundStyle(MobileTheme.Colors.textMuted)
                                                    }
                                                    .font(MobileTheme.Typography.tiny)
                                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(
                                                        Capsule()
                                                            .fill(MobileTheme.Colors.surfaceElevated)
                                                            .overlay(
                                                                Capsule()
                                                                    .stroke(MobileTheme.hermesAureate.opacity(0.32), lineWidth: 0.6)
                                                            )
                                                    )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 1)
                                        .padding(.vertical, 2)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(MobileTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(MobileTheme.Colors.border.opacity(0.36), lineWidth: 0.6)
                        )
                )
            }
        }
    }

    private var interactiveVisualsShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("METRIC INSIGHTS")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.5)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(memory.visuals) { visual in
                        interactiveVisualCard(visual)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    private func interactiveVisualCard(_ visual: MobileProjectMemoryVisual) -> some View {
        let maxValue = max(visual.points.map(\.value).max() ?? 1, 1)

        return AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(visual.title)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(visual.subtitle)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visual.points, id: \.label) { point in
                        let isSelected = selectedVisualPointLabel == point.label
                        Button {
                            HapticBus.send()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                if isSelected {
                                    selectedVisualPointLabel = nil
                                } else {
                                    selectedVisualPointLabel = point.label
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(point.label)
                                        .font(MobileTheme.Typography.tiny)
                                        .fontWeight(isSelected ? .bold : .regular)
                                        .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
                                    Spacer()
                                    Text(point.display)
                                        .font(MobileTheme.Typography.monoTiny)
                                        .fontWeight(isSelected ? .bold : .regular)
                                        .foregroundStyle(isSelected ? MobileTheme.ember : MobileTheme.hermesAureate)
                                }

                                GeometryReader { geo in
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: isSelected ? [MobileTheme.ember, MobileTheme.hermesAureate] : [MobileTheme.hermesAureate.opacity(0.85), MobileTheme.hermesAureate.opacity(0.35)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(8, CGFloat(point.value / maxValue) * geo.size.width), height: isSelected ? 6 : 4)
                                }
                                .frame(height: 6)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 220)
    }

    private var evidenceLibraryShelf: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Evidence Library")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("\(filteredSessions.count) backing logs matched")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()

                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(MobileTheme.hermesAureate)
                }

                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    TextField("Search models, providers...", text: $evidenceSearchText)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    if !evidenceSearchText.isEmpty {
                        Button {
                            evidenceSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(MobileTheme.Colors.border.opacity(0.24), lineWidth: 0.6)
                        )
                )

                // Model Quick Filter Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // "All" chip
                        Button {
                            HapticBus.send()
                            evidenceFilterModel = nil
                        } label: {
                            Text("All")
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.semibold)
                                .foregroundStyle(evidenceFilterModel == nil ? .white : MobileTheme.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(evidenceFilterModel == nil ? AnyShapeStyle(MobileTheme.hermesAureate) : AnyShapeStyle(MobileTheme.Colors.surfaceElevated))
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(uniqueModels, id: \.self) { model in
                            let isSelected = evidenceFilterModel == model
                            Button {
                                HapticBus.send()
                                if isSelected {
                                    evidenceFilterModel = nil
                                } else {
                                    evidenceFilterModel = model
                                }
                            } label: {
                                Text(model)
                                    .font(MobileTheme.Typography.tiny)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(isSelected ? .white : MobileTheme.Colors.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? AnyShapeStyle(MobileTheme.hermesAureate) : AnyShapeStyle(MobileTheme.Colors.surfaceElevated))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }

                // Matched Logs List
                VStack(spacing: 8) {
                    ForEach(filteredSessions.prefix(5)) { session in
                        Button {
                            HapticBus.sheetOpen()
                            selectedSession = session
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(MobileTheme.Colors.colorForModel(session.model).opacity(0.12))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "cpu")
                                        .font(.system(size: 14))
                                        .foregroundStyle(MobileTheme.Colors.colorForModel(session.model))
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.model)
                                        .font(MobileTheme.Typography.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                    Text("\(session.provider.displayName) · \(session.totalTokens.formatAsTokens()) tokens · \(session.startTime.formatted(date: .abbreviated, time: .shortened))")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textMuted)
                                }

                                Spacer()

                                Text(session.cost.formatAsCost())
                                    .font(MobileTheme.Typography.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(MobileTheme.Colors.surfaceElevated)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(MobileTheme.Colors.border.opacity(0.24), lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if filteredSessions.isEmpty {
                        Text("No matching sessions found in local cache.")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers & Actions

    private func metricCapsule(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(1.0)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(value)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.28), lineWidth: 0.5)
                )
        )
    }

    private var freshnessColor: Color {
        switch memory.freshness {
        case .fresh: return MobileTheme.success
        case .needsRefresh: return MobileTheme.warning
        case .stale: return MobileTheme.error
        }
    }

    private func navigateToCitation(_ citation: MobileProjectMemoryCitation) {
        if let matchingSession = allSessions.first(where: { $0.sessionId == citation.sessionID }) {
            HapticBus.sheetOpen()
            selectedSession = matchingSession
        }
    }
}
