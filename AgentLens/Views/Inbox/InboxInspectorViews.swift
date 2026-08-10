import SwiftUI
import OpenBurnBarKernel

// MARK: - Inbox inspector components
//
// The interactive vocabulary for the item detail pane. Three rules hold
// everywhere in this file:
//
//   1. Anything that can be activated says what it will do *before* it is
//      activated (hover label, `.help`, and the accessibility label all carry
//      the same sentence).
//   2. Anything that cannot be activated says why, in words, instead of
//      rendering as a control that does nothing.
//   3. Hover, focus, and press are three distinct visible states. Keyboard
//      users get the same affordances as the mouse.

// MARK: - Navigation

/// The set of places an inbox drill-through can reach. Passed in rather than
/// resolved here so the views stay previewable and testable.
struct InboxDrillNavigator {
    var openSessionLog: (String) -> Void = { _ in }
    var openWeb: (String) -> Void = { _ in }
    var reveal: (String) -> Void = { _ in }
    var openCharts: () -> Void = {}
    /// False in windows that carry no dashboard router (the detached detail
    /// window). A Charts affordance there would be a control that does nothing,
    /// so it is downgraded to an explained inert row instead.
    var chartsAvailable = true

    /// Views ask for the *effective* target so an unreachable destination is
    /// never rendered as a live control.
    func resolve(_ target: InboxDrillTarget) -> InboxDrillTarget {
        if target == .charts, chartsAvailable == false { return .none }
        return target
    }

    func activate(_ target: InboxDrillTarget) {
        switch target {
        case .sessionLog(let id): openSessionLog(id)
        case .web(let url): openWeb(url)
        case .reveal(let path): reveal(path)
        case .charts: openCharts()
        case .none: break
        }
    }
}

// MARK: - Glass

/// The shipped glass recipe (`ChartCardView`), parameterised by accent.
/// Reused verbatim so the inbox inspector belongs to the same surface family as
/// the Charts gallery instead of inventing a second card language.
struct InboxGlassPanel<Content: View>: View {
    var accent: Color = DesignSystem.Colors.ember
    var cornerRadius: CGFloat = DesignSystem.Radius.lg
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                if #available(macOS 26, *) {
                    shape
                        .fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
                        .liquidGlassEffect(.regular, in: shape)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                        shape.fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(accent.opacity(0.22), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Press feedback shared by every interactive row in the pane.
struct InboxPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(DesignSystem.Animation.snappy, value: configuration.isPressed)
    }
}

// MARK: - Section label

struct InboxSectionLabel: View {
    let text: String
    var hint: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            if let hint {
                Text(hint)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metrics section

/// "BY THE NUMBERS", made examinable.
///
/// The affordance is a **single-select inline inspector**, not a tooltip and not
/// a popover. Reasons, in order of weight:
///
///   • A drill-through can be sixteen rows long. A tooltip cannot hold that, and
///     a macOS popover dismisses on scroll — which is exactly what a reader does
///     while comparing a breakdown against the prose above it.
///   • Keeping the panel inline keeps the claim and its evidence on screen
///     together, which is the whole argument of this pane.
///   • Selecting one metric at a time means the layout shifts in one predictable
///     place instead of every chip growing independently.
///
/// Hover still does real work — it reveals the per-metric affordance and the
/// `help` text — so the mouse gets a preview and the click gets the detail.
struct InboxMetricsSection: View {
    let metrics: [InboxMetric]
    let navigator: InboxDrillNavigator

    @State private var selectedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            InboxSectionLabel(
                text: "BY THE NUMBERS",
                hint: metrics.isEmpty ? nil : "click any number to see what it counted"
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168, maximum: 300), spacing: DesignSystem.Spacing.sm)],
                alignment: .leading,
                spacing: DesignSystem.Spacing.sm
            ) {
                ForEach(metrics) { metric in
                    InboxMetricStat(
                        metric: metric,
                        isSelected: selectedKey == metric.key,
                        onToggle: { toggle(metric) }
                    )
                }
            }

            if let selected = metrics.first(where: { $0.key == selectedKey }) {
                InboxMetricInspectorPanel(
                    metric: selected,
                    navigator: navigator,
                    onClose: { toggle(selected) }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .animation(DesignSystem.Animation.gentle, value: selectedKey)
    }

    private func toggle(_ metric: InboxMetric) {
        selectedKey = selectedKey == metric.key ? nil : metric.key
    }
}

/// One number, as a card you can press.
struct InboxMetricStat: View {
    let metric: InboxMetric
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(metric.label.uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .tracking(0.9)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(
                            isSelected || isHovering
                                ? DesignSystem.Colors.ember
                                : DesignSystem.Colors.textMuted.opacity(0.5)
                        )
                }

                Text(metric.value)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(
                        isHovering || isSelected
                            ? DesignSystem.Colors.ember.opacity(0.9)
                            : DesignSystem.Colors.textMuted.opacity(0.8)
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(
                        isSelected
                            ? DesignSystem.Colors.ember.opacity(0.12)
                            : DesignSystem.Colors.surfaceElevated.opacity(isHovering ? 0.85 : 0.55)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected || isFocused ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(InboxPressStyle())
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(DesignSystem.Animation.hover, value: isHovering)
        .animation(DesignSystem.Animation.hover, value: isFocused)
        .help(helpText)
        .accessibilityIdentifier(OBBAccessibilityID.inboxMetric(metric.key))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label), \(metric.value)")
        .accessibilityValue(restingSubtitle)
        .accessibilityHint(metric.explanation)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// At rest the card states what it has; on hover it states what pressing
    /// will do. Both are true, and neither is a tooltip the mouse has to sit
    /// still for.
    private var subtitle: String {
        guard isHovering || isSelected else { return restingSubtitle }
        if isSelected { return "hide breakdown" }
        return metric.hasBreakdown ? "show all \(metric.rows.count)" : "explain this"
    }

    private var restingSubtitle: String {
        guard metric.hasBreakdown else { return "measured, not itemized" }
        return metric.rows.count == 1 ? "1 source cited" : "\(metric.rows.count) sources cited"
    }

    private var helpText: String {
        metric.hasBreakdown
            ? "\(metric.explanation) Click to list the \(metric.rows.count) cited."
            : metric.explanation
    }

    private var borderColor: Color {
        if isSelected { return DesignSystem.Colors.ember.opacity(0.55) }
        if isFocused { return DesignSystem.Colors.ember.opacity(0.75) }
        if isHovering { return DesignSystem.Colors.ember.opacity(0.30) }
        return DesignSystem.Colors.borderSubtle
    }
}

/// The expanded truth behind one number.
struct InboxMetricInspectorPanel: View {
    let metric: InboxMetric
    let navigator: InboxDrillNavigator
    let onClose: () -> Void

    var body: some View {
        InboxGlassPanel(accent: DesignSystem.Colors.ember) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text(metric.label.uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .tracking(1.1)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(metric.value)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .padding(DesignSystem.Spacing.xs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Collapse this breakdown")
                    .accessibilityLabel("Collapse \(metric.label) breakdown")
                }

                Text(metric.explanation)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let coverage = metric.coverageNote {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignSystem.Colors.amber)
                        Text(coverage)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if metric.rows.isEmpty {
                    Text("This number has no itemized sources in the payload — the count is above, and the sentence above it is the whole of what the analyst recorded.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: DesignSystem.Spacing.xxs) {
                        ForEach(metric.rows) { row in
                            InboxDrillRowView(row: row, navigator: navigator)
                        }
                    }
                }

                if let label = navigator.resolve(metric.target).activationLabel {
                    Button {
                        navigator.activate(navigator.resolve(metric.target))
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: navigator.resolve(metric.target).symbol)
                                .font(.system(size: 10, weight: .semibold))
                            Text(label)
                                .font(DesignSystem.Typography.caption)
                        }
                        .foregroundStyle(DesignSystem.Colors.ember)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.ember.opacity(0.12))
                                .overlay(Capsule().stroke(DesignSystem.Colors.ember.opacity(0.35), lineWidth: 1))
                        )
                    }
                    .buttonStyle(InboxPressStyle())
                    .help("\(label) — the surface where this number lives in full")
                }
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxMetric(metric.key) + ".panel")
    }
}

/// One line of a breakdown. Same interaction contract as an evidence row, at a
/// tighter scale.
struct InboxDrillRowView: View {
    let row: InboxDrillRow
    let navigator: InboxDrillNavigator

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var target: InboxDrillTarget { navigator.resolve(row.target) }

    var body: some View {
        Group {
            if target.isReachable {
                Button { navigator.activate(target) } label: { content }
                    .buttonStyle(InboxPressStyle())
                    .focused($isFocused)
                    .focusEffectDisabled()
                    .help(target.activationLabel ?? "")
            } else {
                content
                    .help("No link recorded for this line")
            }
        }
        .onHover { isHovering = $0 }
        .animation(DesignSystem.Animation.hover, value: isHovering)
        .accessibilityIdentifier(OBBAccessibilityID.inboxMetricRow(row.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.detail ?? "")
        .accessibilityHint(target.activationLabel ?? "Reference only, nothing to open")
    }

    private var content: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail {
                    Text(detail)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            if let share = row.share {
                shareBar(share)
            }

            if isHovering, let label = target.activationLabel {
                Text(label)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .lineLimit(1)
                    .fixedSize()
            }

            Image(systemName: target.isReachable ? "chevron.right" : "minus")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    target.isReachable
                        ? (isHovering ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                        : DesignSystem.Colors.textMuted.opacity(0.35)
                )
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(
                    isHovering && target.isReachable
                        ? DesignSystem.Colors.ember.opacity(0.08)
                        : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(isFocused ? DesignSystem.Colors.ember.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    private func shareBar(_ share: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.15))
            GeometryReader { proxy in
                Capsule()
                    .fill(DesignSystem.Colors.ember.opacity(0.65))
                    .frame(width: max(2, proxy.size.width * share))
            }
        }
        .frame(width: 54, height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Evidence

/// One citation, promoted to a first-class control.
///
/// What changed against the flat row it replaces: the full label is reachable
/// (press the disclosure, or copy it from the context menu) instead of being
/// silently truncated; hover names the destination before the click; keyboard
/// focus draws a ring; and a citation with nowhere to go states that in words
/// rather than rendering a disabled button.
struct InboxEvidenceRowView: View {
    let evidence: BurnBarInboxEvidence
    let navigator: InboxDrillNavigator

    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var didCopy = false
    @FocusState private var isFocused: Bool

    private var target: InboxDrillTarget {
        navigator.resolve(InboxEvidenceInspector.target(for: evidence))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if target.isReachable {
                Button { navigator.activate(target) } label: { rowBody }
                    .buttonStyle(InboxPressStyle())
                    .focused($isFocused)
                    .focusEffectDisabled()
                    .help(helpText)
            } else {
                rowBody
                    .help(InboxEvidenceInspector.inertReason(for: evidence))
            }

            if isExpanded { expansion }
        }
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(borderColor, lineWidth: isFocused ? 1.5 : 1)
        )
        .onHover { isHovering = $0 }
        .animation(DesignSystem.Animation.hover, value: isHovering)
        .animation(DesignSystem.Animation.gentle, value: isExpanded)
        .contextMenu {
            Button("Copy title") { copy(evidence.label) }
            if let detail = evidence.detail {
                Button("Copy detail") { copy(detail) }
            }
            Button("Copy reference id") { copy(InboxEvidenceInspector.referenceID(for: evidence)) }
            if case .web(let url) = target {
                Divider()
                Button("Copy link") { copy(url) }
            }
            if case .reveal(let path) = target {
                Divider()
                Button("Copy path") { copy(path) }
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxEvidence(evidence.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Evidence: \(evidence.label)")
        .accessibilityValue(evidence.detail ?? "")
        .accessibilityHint(target.activationLabel ?? InboxEvidenceInspector.inertReason(for: evidence))
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: InboxPresentation.evidenceIcon(for: evidence.kind))
                .font(.system(size: 11))
                .foregroundStyle(
                    target.isReachable && isHovering
                        ? DesignSystem.Colors.ember
                        : DesignSystem.Colors.textMuted
                )
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(evidence.label)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    if let detail = evidence.detail {
                        Text(detail)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                    if let occurredAt = evidence.occurredAt {
                        Text("· \(InboxView.relativeFormatter.localizedString(for: occurredAt, relativeTo: Date()))")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            trailing
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            // Always present, never hover-only: a control that exists solely
            // under the cursor is invisible to the keyboard and to VoiceOver.
            // It sits quiet at rest and leans forward when the label is long
            // enough that something is actually being hidden.
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.9))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(disclosureOpacity)
            .help(isExpanded ? "Hide the full citation" : "Show the full citation, id, and copy actions")
            .accessibilityLabel(isExpanded ? "Hide full citation" : "Show full citation")

            if isHovering, let label = target.activationLabel {
                Text(label)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .lineLimit(1)
                    .fixedSize()
            }

            if target.isReachable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovering ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
            } else if isHovering {
                Text("no link")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    .fixedSize()
            }
        }
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Divider().background(DesignSystem.Colors.borderSubtle)

            Text(evidence.label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = evidence.detail {
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(InboxEvidenceInspector.referenceID(for: evidence))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button { copy(InboxEvidenceInspector.referenceID(for: evidence)) } label: {
                    Text(didCopy ? "Copied" : "Copy id")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(didCopy ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }

            if target.isReachable == false {
                Text(InboxEvidenceInspector.inertReason(for: evidence))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var helpText: String {
        guard let label = target.activationLabel else { return evidence.label }
        return "\(label) — \(evidence.label)"
    }

    /// Louder when the two-line clamp is actually hiding something.
    private var disclosureOpacity: Double {
        if isHovering || isExpanded { return 1 }
        return InboxEvidenceInspector.isTruncationLikely(evidence.label) ? 0.55 : 0.25
    }

    private var backgroundFill: Color {
        if target.isReachable && isHovering { return DesignSystem.Colors.ember.opacity(0.07) }
        return DesignSystem.Colors.surfaceElevated.opacity(target.isReachable ? 0.5 : 0.32)
    }

    private var borderColor: Color {
        if isFocused { return DesignSystem.Colors.ember.opacity(0.75) }
        if target.isReachable && isHovering { return DesignSystem.Colors.ember.opacity(0.28) }
        return DesignSystem.Colors.borderSubtle.opacity(target.isReachable ? 1 : 0.5)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            didCopy = false
        }
    }
}

// MARK: - Actions

/// "NEXT", with a real hierarchy.
///
/// One primary action, rendered wide and filled. Everything else is a
/// secondary capsule. A `runCommand` never renders as either — it gets a
/// command card that shows the text, labels itself as copy-only, and flags a
/// destructive-looking payload, because a button that looks like "go" must
/// never be a button that only copies.
struct InboxActionsSection: View {
    let actions: [BurnBarInboxAction]
    let settingsAvailable: Bool
    let onOpenSessionLog: (String) -> Void
    let onOpenSettings: (() -> Void)?
    let navigator: InboxDrillNavigator

    var body: some View {
        let split = InboxActionInspector.partition(actions)
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            InboxSectionLabel(text: "NEXT")

            if let primary = split.primary {
                actionControl(primary, isPrimary: true)
            }

            ForEach(split.secondary) { action in
                actionControl(action, isPrimary: false)
            }
        }
    }

    @ViewBuilder
    private func actionControl(_ action: BurnBarInboxAction, isPrimary: Bool) -> some View {
        let readiness = InboxActionInspector.readiness(
            for: action,
            settingsAvailable: settingsAvailable || onOpenSettings != nil,
            pathExists: { FileManager.default.fileExists(atPath: $0) }
        )
        if action.kind == .runCommand {
            InboxCommandCard(action: action, readiness: readiness)
        } else {
            InboxActionButton(
                action: action,
                readiness: readiness,
                isPrimary: isPrimary,
                perform: { perform(action) }
            )
        }
    }

    private func perform(_ action: BurnBarInboxAction) {
        switch action.kind {
        case .openURL:
            navigator.openWeb(action.value)
        case .resumeConversation, .openSessionLog:
            onOpenSessionLog(action.value)
        case .openProject:
            navigator.reveal(action.value)
        case .openSettings:
            onOpenSettings?()
        case .runCommand:
            break
        }
    }
}

struct InboxActionButton: View {
    let action: BurnBarInboxAction
    let readiness: InboxActionReadiness
    let isPrimary: Bool
    let perform: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            Button(action: perform) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: InboxPresentation.actionIcon(for: action.kind))
                        .font(.system(size: 12, weight: .semibold))
                    Text(action.title)
                        .font(isPrimary ? DesignSystem.Typography.body.weight(.semibold) : DesignSystem.Typography.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: DesignSystem.Spacing.sm)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(readiness.isEnabled ? (isHovering ? 1 : 0.55) : 0.25)
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, isPrimary ? DesignSystem.Spacing.md : DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(
                            isFocused ? DesignSystem.Colors.ember.opacity(0.85) : Color.clear,
                            lineWidth: 2
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }
            .buttonStyle(InboxPressStyle())
            .disabled(readiness.isEnabled == false)
            .focused($isFocused)
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            .animation(DesignSystem.Animation.hover, value: isHovering)
            .help(readiness.disabledReason ?? readiness.effect)

            // The explanation is never hidden behind the disabled state: a
            // control the user cannot press still has to say why.
            Text(readiness.disabledReason ?? readiness.effect)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(
                    readiness.isEnabled
                        ? DesignSystem.Colors.textMuted
                        : DesignSystem.Colors.warning.opacity(0.9)
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DesignSystem.Spacing.xs)
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxAction(action.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityHint(readiness.disabledReason ?? readiness.effect)
        .accessibilityAddTraits(.isButton)
    }

    private var foreground: Color {
        if readiness.isEnabled == false { return DesignSystem.Colors.textMuted }
        return isPrimary ? .white : DesignSystem.Colors.textPrimary
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
        if readiness.isEnabled == false {
            shape
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.35))
                .overlay(shape.stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1))
        } else if isPrimary {
            shape
                .fill(DesignSystem.Colors.primaryGradient)
                .opacity(isHovering ? 1 : 0.92)
        } else {
            shape
                .fill(DesignSystem.Colors.surfaceElevated.opacity(isHovering ? 0.9 : 0.6))
                .overlay(
                    shape.stroke(
                        isHovering ? DesignSystem.Colors.ember.opacity(0.35) : DesignSystem.Colors.borderSubtle,
                        lineWidth: 1
                    )
                )
        }
    }
}

/// A suggested shell command. Deliberately not a "go" button.
struct InboxCommandCard: View {
    let action: BurnBarInboxAction
    let readiness: InboxActionReadiness

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                Text(action.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                Text("COPY ONLY")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(0.9)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.9)))
            }
            .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(action.value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                        )
                )

            if let caution = readiness.caution {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text(caution)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(action.value, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied to clipboard" : "Copy command", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(didCopy ? DesignSystem.Colors.success : DesignSystem.Colors.textPrimary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.85))
                                .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1))
                        )
                }
                .buttonStyle(InboxPressStyle())
                .disabled(readiness.isEnabled == false)

                Text(readiness.disabledReason ?? readiness.effect)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(
                            readiness.caution == nil
                                ? DesignSystem.Colors.borderSubtle
                                : DesignSystem.Colors.warning.opacity(0.45),
                            lineWidth: 1
                        )
                )
        )
        .accessibilityIdentifier(OBBAccessibilityID.inboxAction(action.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(action.title). Copy only, nothing runs.")
        .accessibilityHint(readiness.caution ?? readiness.effect)
    }
}

// MARK: - Occurrence

/// "seen 161 times", made examinable.
struct InboxOccurrenceControl: View {
    let summary: InboxOccurrenceSummary

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Text("seen \(InboxMetricInspector.groupedCount(Double(summary.count)))×")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(
                            isHovering || isExpanded
                                ? DesignSystem.Colors.ember
                                : DesignSystem.Colors.textMuted
                        )
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(
                            isHovering || isExpanded
                                ? DesignSystem.Colors.ember
                                : DesignSystem.Colors.textMuted.opacity(0.6)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(DesignSystem.Animation.hover, value: isHovering)
            .help("How often this exact condition has recurred")
            .accessibilityIdentifier(OBBAccessibilityID.inboxOccurrence)
            .accessibilityLabel("Seen \(summary.count) times")
            .accessibilityHint(summary.explanation)

            if isExpanded {
                InboxGlassPanel(accent: DesignSystem.Colors.whimsy, cornerRadius: DesignSystem.Radius.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        occurrenceLine("First seen", InboxOccurrenceInspector.absoluteFormatter.string(from: summary.firstSeen))
                        occurrenceLine("Last seen", InboxOccurrenceInspector.absoluteFormatter.string(from: summary.lastSeen))
                        occurrenceLine("Running for", summary.span)
                        if let cadence = summary.cadence {
                            occurrenceLine("Cadence", cadence)
                        }
                        Text(summary.explanation)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 420)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DesignSystem.Animation.gentle, value: isExpanded)
    }

    private func occurrenceLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Text(label.uppercased())
                .font(DesignSystem.Typography.tiny)
                .tracking(0.9)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
