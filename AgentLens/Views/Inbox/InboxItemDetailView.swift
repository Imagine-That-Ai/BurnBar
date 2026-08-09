import SwiftUI
import OpenBurnBarKernel

/// The reading surface for one inbox item — a visual delight every time.
///
/// # Design: "Evidence as Story"
/// An inbox item is a claim about your work that may be wrong. The detail
/// answers three questions in order: **What?** (hero + narrative), **Why should
/// I believe it?** (evidence timeline you can tap), **What now?** (actions).
/// The chrome is warm ledger paper; the story is the hero. Every state —
/// unread, resolved, snoozed — has its own mood, not just its own badge.
///
/// Visual delight comes from: a hero that glows with the item's kind tint,
/// a soft dot-field constellation behind the scroll (the same field you see when
/// empty, but now it peeks behind the cards), spring-reveals, and cards that
/// lift on hover. Nothing is sterile. Metrics are little charms, evidence is a
/// timeline you want to trace with your finger, actions are big friendly pills
/// that look like you should tap them (because you should).
struct InboxItemDetailView: View {
    let row: ControlPlaneStore.AIInboxRow
    let onOpenSessionLog: (String) -> Void
    let onArchive: () -> Void
    let onSnooze: (TimeInterval) -> Void
    let onFeedback: (Bool?) -> Void
    var onOpenSettings: (() -> Void)?

    var memoryApproval: InboxMemoryApprovalHandler?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                hero
                if row.summaryMarkdown.isEmpty == false { narrative }
                if row.payload.metrics.isEmpty == false { metricsCharmRow }
                if row.payload.evidence.isEmpty == false { evidenceTimeline }
                if row.payload.memoryCandidates.isEmpty == false { memoryTheatre }
                if row.payload.actions.isEmpty == false { actionsPromenade }
                footerCast
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(detailBackground)
        .onAppear {
            guard !reduceMotion else { appear = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appear = true }
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxDetail)
    }

    // MARK: - Background

    private var detailBackground: some View {
        ZStack {
            DesignSystem.Colors.background.opacity(0.65)
            // Soft dot-constellation — the same field as the empty state, but whisper-quiet behind content
            GeometryReader { geo in
                Canvas { ctx, size in
                    let dotCount = 180
                    var rng = SeededRNG(seed: UInt64(abs(row.id.hashValue)))
                    for _ in 0..<dotCount {
                        let x = CGFloat(rng.next() % 1000) / 1000 * size.width
                        let y = CGFloat(rng.next() % 1000) / 1000 * size.height
                        let r: CGFloat = (rng.next() % 2 == 0) ? 1.0 : 1.4
                        let alpha: Double = 0.07 + Double(rng.next() % 60) / 1000
                        let tint: Color = {
                            let v = rng.next() % 3
                            if v == 0 { return DesignSystem.Colors.ember }
                            if v == 1 { return DesignSystem.Colors.amber }
                            return DesignSystem.Colors.whimsy
                        }()
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                            with: .color(tint.opacity(alpha))
                        )
                    }
                }
                .allowsHitTesting(false)
                .opacity(0.55)
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                // Kind icon in tinted capsule that glows
                ZStack {
                    Circle()
                        .fill(InboxPresentation.tint(for: row.summary.kind).opacity(colorScheme == .dark ? 0.22 : 0.14))
                        .frame(width: 36, height: 36)
                        .blur(radius: 6)
                    Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(DesignSystem.Colors.surfaceElevated)
                                .shadow(color: InboxPresentation.tint(for: row.summary.kind).opacity(0.18), radius: 8, y: 3)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(InboxPresentation.kindLabel(row.summary.kind).uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .tracking(1.1)
                        .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                    if let project = row.summary.projectName, !project.isEmpty {
                        Text(project)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                OpenBurnBarStatusBadge(
                    title: InboxPresentation.priorityLabel(row.summary.priority),
                    color: InboxPresentation.priorityColor(row.summary.priority)
                )

                if row.summary.state == .resolved {
                    Label("Resolved", systemImage: "checkmark.seal.fill")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DesignSystem.Colors.success))
                } else if row.isUnread {
                    Circle().fill(DesignSystem.Colors.ember).frame(width: 8, height: 8)
                }
            }

            Text(row.summary.title)
                .font(DesignSystem.Typography.display)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            HStack(spacing: DesignSystem.Spacing.xs) {
                Label("first seen \(InboxView.relativeFormatter.localizedString(for: row.summary.firstSeenAt, relativeTo: Date()))", systemImage: "clock")
                if row.summary.occurrenceCount > 1 {
                    Text("· seen \(row.summary.occurrenceCount)×")
                }
                if let until = row.snoozedUntil, until > Date() {
                    Text("· snoozed")
                }
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)

            if let note = row.summary.resolutionNote, row.summary.state == .resolved {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text(note)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                        .fill(DesignSystem.Colors.success.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                                .stroke(DesignSystem.Colors.success.opacity(0.22), lineWidth: 1)
                        )
                )
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surface)
                .shadow(color: InboxPresentation.tint(for: row.summary.kind).opacity(0.10), radius: 18, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                        .stroke(
                            LinearGradient(
                                colors: [InboxPresentation.tint(for: row.summary.kind).opacity(0.18), DesignSystem.Colors.border.opacity(0.5)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ), lineWidth: 0.75
                        )
                )
        )
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 8)
    }

    // MARK: - Narrative

    private var narrative: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("THE STORY", systemImage: "text.alignleft")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.05)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(attributedBody)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 6)
        .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.06), value: appear)
    }

    private var attributedBody: AttributedString {
        (try? AttributedString(
            markdown: row.summaryMarkdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(row.summaryMarkdown)
    }

    // MARK: - Metrics as charms

    private var metricsCharmRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("BY THE NUMBERS", systemImage: "chart.bar")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.05)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            // Flow layout of charm pills
            WrappingHStack(spacing: 8) {
                ForEach(displayMetrics, id: \.key) { metric in
                    HStack(spacing: 6) {
                        Text(metric.label.uppercased())
                            .font(DesignSystem.Typography.monoTiny)
                            .tracking(0.6)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(metric.value)
                            .font(DesignSystem.Typography.mono)
                            .foregroundStyle(metric.isHighlighted ? InboxPresentation.tint(for: row.summary.kind) : DesignSystem.Colors.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.surface)
                            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                    )
                    .overlay(
                        Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
            }
        }
    }

    private var displayMetrics: [(key: String, label: String, value: String, isHighlighted: Bool)] {
        row.payload.metrics
            .filter { $0.key != "calibration_note" }
            .sorted { $0.key < $1.key }
            .map { key, value in
                let label = key.replacingOccurrences(of: "_", with: " ")
                let display: String
                let highlighted: Bool
                if key.hasSuffix("_rate"), let n = Double(value) {
                    display = "\(Int((n * 100).rounded()))%"
                    highlighted = n >= 0.5
                } else if key.hasSuffix("_usd"), let n = Double(value) {
                    display = String(format: "$%.3f", n)
                    highlighted = n > 0
                } else if key.hasSuffix("_minutes"), let n = Double(value) {
                    display = "\(Int(n.rounded()))m"
                    highlighted = n >= 30
                } else {
                    display = value
                    highlighted = false
                }
                return (key, label, display, highlighted)
            }
    }

    // MARK: - Evidence timeline (the delight)

    private var evidenceTimeline: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label("EVIDENCE — TAP TO VERIFY", systemImage: "link")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.05)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            // Timeline spine + cards
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(row.payload.evidence.enumerated()), id: \.element.id) { idx, evidence in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        // Spine
                        VStack(spacing: 0) {
                            ZStack {
                                Circle()
                                    .fill(DesignSystem.Colors.surface)
                                    .frame(width: 28, height: 28)
                                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                                Image(systemName: InboxPresentation.evidenceIcon(for: evidence.kind))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                            }
                            if idx < row.payload.evidence.count - 1 {
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [InboxPresentation.tint(for: row.summary.kind).opacity(0.18), DesignSystem.Colors.borderSubtle],
                                            startPoint: .top, endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 2)
                                    .frame(minHeight: 28)
                                    .padding(.vertical, 4)
                            } else {
                                Spacer(minLength: 0)
                            }
                        }

                        // Card
                        Button { open(evidence) } label: {
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(evidence.label)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .lineLimit(1)
                                    if let detail = evidence.detail {
                                        Text(detail)
                                            .font(DesignSystem.Typography.caption)
                                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                                            .lineLimit(1)
                                    }
                                    if let url = evidence.url {
                                        Text(url)
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if evidence.url != nil {
                                    ZStack {
                                        Circle().fill(InboxPresentation.tint(for: row.summary.kind).opacity(0.12)).frame(width: 26, height: 26)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                                    }
                                }
                            }
                            .padding(DesignSystem.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                                    .fill(DesignSystem.Colors.surfaceElevated)
                                    .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(evidence.url == nil)
                        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md))
                    }
                    .opacity(appear ? 1 : 0)
                    .offset(x: appear ? 0 : -6)
                    .animation(.spring(response: 0.45, dampingFraction: 0.82).delay(Double(idx) * 0.04 + 0.08), value: appear)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surface.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.03), radius: 12, y: 4)
    }

    // MARK: - Memory theatre

    private var memoryTheatre: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "brain.head.profile").foregroundStyle(DesignSystem.Colors.whimsy)
                Text("WORTH REMEMBERING").font(DesignSystem.Typography.tiny).tracking(1.05).foregroundStyle(DesignSystem.Colors.whimsy)
                Spacer()
                Text("quarantined · needs your OK").font(DesignSystem.Typography.monoTiny).foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Text("These are proposals. Nothing is saved — or used in any prompt — until you tap Remember.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(row.payload.memoryCandidates) { candidate in
                InboxMemoryCandidateCard(
                    candidate: candidate,
                    itemFingerprint: row.summary.fingerprint,
                    handler: memoryApproval
                )
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(
                    LinearGradient(
                        colors: [DesignSystem.Colors.whimsy.opacity(0.08), DesignSystem.Colors.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                        .stroke(DesignSystem.Colors.whimsy.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions promenade

    private var actionsPromenade: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("WHAT NOW?", systemImage: "wand.and.stars")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.05)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            WrappingHStack(spacing: 10) {
                ForEach(row.payload.actions) { action in
                    Button { perform(action) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: InboxPresentation.actionIcon(for: action.kind))
                                .font(.system(size: 12, weight: .semibold))
                            Text(action.title)
                                .font(DesignSystem.Typography.headline)
                        }
                        .foregroundStyle(action.isPrimary ? .white : DesignSystem.Colors.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            action.isPrimary
                                ? AnyView(Capsule().fill(
                                    LinearGradient(colors: [InboxPresentation.tint(for: row.summary.kind), DesignSystem.Colors.ember],
                                                   startPoint: .leading, endPoint: .trailing)
                                  ).shadow(color: InboxPresentation.tint(for: row.summary.kind).opacity(0.22), radius: 8, y: 3))
                                : AnyView(Capsule()
                                    .fill(DesignSystem.Colors.surfaceElevated)
                                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                                    .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1))
                                  )
                        )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(appear ? 1 : 0.96)
                    .animation(.spring(response: 0.4, dampingFraction: 0.78).delay(0.12), value: appear)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Footer cast

    private var footerCast: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Divider().background(DesignSystem.Colors.borderSubtle)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: provenanceIcon).font(.system(size: 10)).foregroundStyle(DesignSystem.Colors.textMuted)
                Text(provenanceText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button { onFeedback(row.feedback == "useful" ? nil : true) } label: {
                    Label("Useful", systemImage: row.feedback == "useful" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(row.feedback == "useful" ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)

                Button { onFeedback(row.feedback == "not_useful" ? nil : false) } label: {
                    Label("Not useful", systemImage: row.feedback == "not_useful" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(row.feedback == "not_useful" ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted)

                Spacer()

                Menu {
                    Button("Snooze for an hour") { onSnooze(3_600) }
                    Button("Snooze until tomorrow") { onSnooze(24 * 3_600) }
                    Button("Snooze for a week") { onSnooze(7 * 24 * 3_600) }
                } label: {
                    Label("Snooze", systemImage: "clock")
                        .font(DesignSystem.Typography.caption)
                }
                .menuStyle(.borderlessButton)

                Button(action: onArchive) {
                    Label("Archive", systemImage: "archivebox")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    // MARK: - Helpers

    private var provenanceIcon: String {
        switch row.summary.modelProvenance {
        case "local-rules": return "cpu"
        case let p where p.contains("+"): return "point.3.filled.connected.trianglepath.dotted"
        default: return "sparkles"
        }
    }

    private var provenanceText: String {
        let m = row.summary.modelProvenance
        let v = row.payload.verification
        if let v, v.verdict != .unverified {
            return "Model: \(m) · Verification: \(v.verdict.rawValue) — \(v.reason ?? "")"
        }
        if m == "local-rules" { return "By the numbers — no model was called for this item." }
        return "Model: \(m)"
    }

    private func open(_ evidence: BurnBarInboxEvidence) {
        guard let urlString = evidence.url, let url = URL(string: urlString) else { return }
        if evidence.kind == .conversation, url.scheme == "openburnbar" {
            let id = url.lastPathComponent
            onOpenSessionLog(id)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func perform(_ action: BurnBarInboxAction) {
        switch action.kind {
        case .openURL:
            if let url = URL(string: action.value) { NSWorkspace.shared.open(url) }
        case .openSessionLog:
            onOpenSessionLog(action.value)
        case .openSettings:
            onOpenSettings?()
        case .openProject:
            if let url = URL(string: action.value) { NSWorkspace.shared.open(url) }
        case .resumeConversation:
            onOpenSessionLog(action.value)
        case .runCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(action.value, forType: .string)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .tracking(1.05)
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }
}

// MARK: - Wrapping HStack (flow layout)

private struct WrappingHStack<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content
    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }
    var body: some View {
        // Use the existing flow layout from Elder Wand, or fallback to LazyVGrid
        // Keeping it simple with a flexible wrap via ViewThatFits + HStack
        // For now, a horizontal flow that wraps via `ElderWandFlowLayout` if available, else HStack
        content()
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Seeded RNG for dot field

private struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}
struct InboxMemoryCandidateCard: View {
    let candidate: BurnBarInboxMemoryCandidate
    let itemFingerprint: String
    let handler: InboxMemoryApprovalHandler?

    @State private var state: ApprovalState = .pending
    @State private var errorMessage: String?

    enum ApprovalState: Equatable {
        case pending
        case working
        case approved
        case dismissed
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(candidate.kind.uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.amber)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystem.Colors.amber.opacity(0.14)))

                    Spacer(minLength: 0)

                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 9))
                    Text("\(Int((candidate.confidence * 100).rounded()))%")
                        .font(DesignSystem.Typography.monoTiny)
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(candidate.text)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let errorMessage {
                    Text(errorMessage)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }

                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .pending:
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button { approve() } label: {
                    Text("Remember this")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(.plain)
                .disabled(handler == nil)

                Button { state = .dismissed } label: {
                    Text("Dismiss")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if handler == nil {
                    Text("Memory is unavailable")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        case .working:
            ProgressView().controlSize(.small)
        case .approved:
            Label("Saved to memory", systemImage: "checkmark.seal.fill")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.success)
        case .dismissed:
            Label("Dismissed", systemImage: "xmark.circle")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func approve() {
        guard let handler else { return }
        state = .working
        errorMessage = nil
        Task {
            do {
                try await handler.approve(candidate: candidate, itemFingerprint: itemFingerprint)
                state = .approved
            } catch {
                state = .pending
                errorMessage = error.localizedDescription
            }
        }
    }
}
