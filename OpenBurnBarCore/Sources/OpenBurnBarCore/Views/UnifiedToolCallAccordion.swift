import SwiftUI

// MARK: - Unified Tool Call Accordion
//
// One renderer for the tool calls every chat surface emits — Hermes, Pi,
// and every CLI agent (Codex, Claude, Droid, Forge, …) on iOS, plus the
// AgentLens chat transcripts on macOS. Before this existed each surface
// carried its own copy of a horizontally-scrolling pill strip that showed
// *every* tool call at once; the copies drifted and the strips were noisy.
//
// The accordion stays collapsed by default and shows only the **most
// recent** tool call between two messages. Tapping it reveals the full
// history with each call's one-line summary plus the raw arguments (and,
// where a runtime captures one, the result). While a tool is still running
// the row stays collapsed and its status dot pulses — the surface never
// auto-expands underneath the reader.
//
// Surfaces map their native tool-call model into `UnifiedToolCallDisplay`
// and pass the accent they already use so each runtime keeps its identity.
// The component is self-contained (no app-target dependencies) so it can
// live in `OpenBurnBarCore` and serve both apps.

// MARK: - Display Model

/// Surface-agnostic description of a single tool invocation. Each chat
/// surface maps its native model (`HermesToolCall`, `PiToolCall`,
/// `CLIAgentToolUse`, `ChatTranscriptPiece`) into this value type.
public struct UnifiedToolCallDisplay: Identifiable, Equatable {

    /// Visual state that drives the status dot's colour and pulse.
    public enum State: Equatable {
        case running
        case done
        case failed
        case neutral
    }

    public let id: String
    public let name: String
    /// The runtime's free-form status string (`"running"`, `"done"`,
    /// `"failed"`, or anything a future runtime emits). Preserved verbatim
    /// for display; classified leniently into `state`.
    public let statusRaw: String?
    /// Short human-readable summary already captured by every surface — a
    /// file path, command, or query.
    public let detail: String?
    /// Raw concatenated arguments (JSON or string). Hermes and Pi capture
    /// this; CLI agents and the Mac transcript leave it `nil`.
    public let arguments: String?
    /// Tool result text, when a runtime pairs one with the call (the Mac
    /// transcript pairs a following `.toolResult` piece). `nil` elsewhere.
    public let result: String?
    /// Whether this call is still in flight on the current streaming turn.
    public let isRunning: Bool

    public init(
        id: String,
        name: String,
        statusRaw: String? = nil,
        detail: String? = nil,
        arguments: String? = nil,
        result: String? = nil,
        isRunning: Bool = false
    ) {
        self.id = id
        self.name = name
        self.statusRaw = statusRaw
        self.detail = detail
        self.arguments = arguments
        self.result = result
        self.isRunning = isRunning
    }

    /// Lenient classification of the runtime's status string. A live call
    /// always wins so a mid-stream tool pulses even before a status lands.
    public var state: State {
        if isRunning { return .running }
        guard let raw = statusRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else { return .neutral }
        if raw.contains("fail") || raw.contains("error") || raw.contains("denied")
            || raw.contains("cancel") || raw.contains("timeout") || raw.contains("reject") {
            return .failed
        }
        if raw.contains("done") || raw.contains("complete") || raw.contains("finish")
            || raw.contains("success") || raw.contains("ok") || raw.contains("ran") {
            return .done
        }
        if raw.contains("run") || raw.contains("pending") || raw.contains("active")
            || raw.contains("stream") || raw.contains("progress") || raw.contains("start") {
            return .running
        }
        return .neutral
    }

    /// Whether expanding reveals more than the collapsed row already shows.
    public var hasExpandableDetail: Bool {
        let trimmed: (String?) -> Bool = { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
        return trimmed(arguments) || trimmed(result)
    }

    /// SF Symbol for this tool. The single canonical version of the icon
    /// switch that used to be copied into four separate views.
    public var iconName: String { Self.iconName(for: name) }

    public static func iconName(for name: String) -> String {
        let n = name.lowercased()
        // Order matters — specific keywords must precede broad ones so that
        // e.g. "search_files" resolves to magnifyingglass (not doc.text) and
        // "web_search" resolves to globe (not magnifyingglass).
        if n.contains("bash") || n.contains("exec") || n.contains("terminal") { return "terminal" }
        if n.contains("memory") || n.contains("skill") || n.contains("learn") { return "brain" }
        if n.contains("image") || n.contains("vision") || n.contains("screenshot") { return "photo" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") || n.contains("http") { return "globe" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") || n.contains("find") { return "magnifyingglass" }
        if n.contains("edit") || n.contains("patch") || n.contains("replace") { return "pencil.and.outline" }
        if n.contains("read") || n.contains("write") || n.contains("file") { return "doc.text" }
        if n.contains("run") { return "terminal" }
        return "wrench.and.screwdriver.fill"
    }
}

// MARK: - Accent

/// Per-surface visual identity. Carries the tint used for the icon and the
/// gradient stroke that frames the card, so Hermes keeps its mercury sheen,
/// Pi its whimsy, and each CLI agent its own colour.
public struct UnifiedToolCallAccent {
    public let tint: Color
    public let strokeStyle: AnyShapeStyle

    public init(tint: Color, strokeStyle: AnyShapeStyle) {
        self.tint = tint
        self.strokeStyle = strokeStyle
    }

    /// Hermes — aureate tint with the mercury foil stroke.
    public static let hermes = UnifiedToolCallAccent(
        tint: UnifiedDesignSystem.Colors.hermesAureate,
        strokeStyle: AnyShapeStyle(UnifiedDesignSystem.mercuryGradient.opacity(0.7))
    )

    /// Pi — whimsy tint and gradient.
    public static let pi = UnifiedToolCallAccent(
        tint: UnifiedDesignSystem.Colors.whimsy,
        strokeStyle: AnyShapeStyle(UnifiedDesignSystem.piGradient.opacity(0.7))
    )

    /// macOS assistant default when the surface isn't Hermes-branded.
    public static let macAssistant = UnifiedToolCallAccent(
        tint: UnifiedDesignSystem.Colors.ember,
        strokeStyle: AnyShapeStyle(UnifiedDesignSystem.primaryGradient.opacity(0.6))
    )

    /// CLI agent — any per-runtime brand colour, with a stroke derived from it.
    public static func agent(_ color: Color) -> UnifiedToolCallAccent {
        UnifiedToolCallAccent(
            tint: color,
            strokeStyle: AnyShapeStyle(
                LinearGradient(
                    colors: [color.opacity(0.75), color.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        )
    }
}

// MARK: - Accordion

/// Collapsed-by-default disclosure for a message's tool calls. Renders the
/// most recent call as a single compact row; tap to reveal the full history
/// with arguments and results.
public struct UnifiedToolCallAccordion: View {
    private let calls: [UnifiedToolCallDisplay]
    private let accent: UnifiedToolCallAccent

    @State private var isExpanded = false

    /// - Parameters:
    ///   - calls: tool calls in chronological order (oldest first). The last
    ///     element is treated as the most recent and shown when collapsed.
    ///   - accent: the surface's brand tint and stroke.
    public init(calls: [UnifiedToolCallDisplay], accent: UnifiedToolCallAccent) {
        self.calls = calls
        self.accent = accent
    }

    /// Most recent call drives the collapsed row.
    private var mostRecent: UnifiedToolCallDisplay? { Self.mostRecent(of: calls) }

    /// Older calls revealed on expand, newest first.
    private var olderCalls: [UnifiedToolCallDisplay] { Array(calls.dropLast().reversed()) }

    /// Expansion is worth offering when there's history to show or the most
    /// recent call carries arguments/results beyond its one-line summary.
    private var isExpandable: Bool {
        calls.count > 1 || (mostRecent?.hasExpandableDetail ?? false)
    }

    private var extraCount: Int { Self.additionalCount(of: calls) }

    /// The call shown when collapsed — always the newest (chronological last).
    public static func mostRecent(of calls: [UnifiedToolCallDisplay]) -> UnifiedToolCallDisplay? {
        calls.last
    }

    /// How many calls the `+N` badge represents (everything but the newest).
    public static func additionalCount(of calls: [UnifiedToolCallDisplay]) -> Int {
        max(0, calls.count - 1)
    }

    public var body: some View {
        if let mostRecent {
            VStack(alignment: .leading, spacing: 0) {
                header(mostRecent)
                if isExpanded {
                    expandedBody(mostRecent)
                }
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surface.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .stroke(accent.strokeStyle, lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous))
            .animation(UnifiedDesignSystem.Animation.standard, value: isExpanded)
        }
    }

    // MARK: Header (collapsed row / toggle)

    @ViewBuilder
    private func header(_ call: UnifiedToolCallDisplay) -> some View {
        let row = HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: call.iconName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent.tint)

            Text(call.name)
                .font(UnifiedDesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(accent.tint)
                .lineLimit(1)

            if let detail = trimmed(call.detail) {
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }

            Spacer(minLength: UnifiedDesignSystem.Spacing.xs)

            if extraCount > 0, !isExpanded {
                Text("+\(extraCount)")
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.9))
                    )
            }

            StatusDot(state: call.state, tint: accent.tint)

            if isExpandable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }

        if isExpandable {
            Button {
                isExpanded.toggle()
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tool call \(call.name), \(accessibilityStatus(call.state))")
            .accessibilityHint(isExpanded
                ? "Collapse tool calls"
                : (calls.count > 1
                    ? "Expand \(calls.count) tool calls"
                    : "Expand to see details")
            )
            .accessibilityAddTraits(.isButton)
        } else {
            row
        }
    }

    // MARK: Expanded body

    @ViewBuilder
    private func expandedBody(_ mostRecent: UnifiedToolCallDisplay) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Divider()
                .overlay(accent.tint.opacity(0.18))
                .padding(.top, UnifiedDesignSystem.Spacing.sm)

            detailRows(mostRecent)
            ForEach(olderCalls) { call in
                Divider().overlay(UnifiedDesignSystem.Colors.border.opacity(0.4))
                detailRows(call)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// One expanded call: name + status, summary, and raw arguments/result.
    @ViewBuilder
    private func detailRows(_ call: UnifiedToolCallDisplay) -> some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: call.iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent.tint)
                Text(call.name)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(accent.tint)
                Spacer(minLength: UnifiedDesignSystem.Spacing.xs)
                StatusDot(state: call.state, tint: accent.tint)
                if let status = trimmed(call.statusRaw) {
                    Text(status)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }

            if let detail = trimmed(call.detail) {
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            if let arguments = trimmed(call.arguments) {
                monospacedBlock(label: "arguments", text: arguments)
            }
            if let result = trimmed(call.result) {
                monospacedBlock(label: "result", text: result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inset monospaced block for raw arguments or results.
    @ViewBuilder
    private func monospacedBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .tracking(0.5)
            Text(text)
                .font(UnifiedDesignSystem.Typography.monoTiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(10)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(UnifiedDesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                        .fill(UnifiedDesignSystem.Colors.background.opacity(0.55))
                )
        }
    }

    // MARK: Helpers

    private func trimmed(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    private func accessibilityStatus(_ state: UnifiedToolCallDisplay.State) -> String {
        switch state {
        case .running: return "running"
        case .done:    return "done"
        case .failed:  return "failed"
        case .neutral: return "completed"
        }
    }
}

// MARK: - Status Dot

/// Small state indicator. Pulses while a call is running; otherwise a solid
/// dot tinted green (done), red (failed), the surface accent (running with no
/// animation context), or muted (neutral).
private struct StatusDot: View {
    let state: UnifiedToolCallDisplay.State
    let tint: Color

    @State private var pulsing = false

    private var color: Color {
        switch state {
        case .running: return tint
        case .done:    return UnifiedDesignSystem.Colors.success
        case .failed:  return UnifiedDesignSystem.Colors.error
        case .neutral: return UnifiedDesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(state == .running && pulsing ? 0.35 : 1)
            .scaleEffect(state == .running && pulsing ? 0.78 : 1)
            .onAppear { startPulseIfRunning() }
            .onChange(of: state) { _, newState in
                if newState == .running {
                    // Re-entered running state (e.g. a second tool call started
                    // on the same turn after an earlier one completed).
                    startPulseIfRunning()
                } else {
                    // Settled — stop animation and reset scale/opacity.
                    withAnimation(UnifiedDesignSystem.Animation.standard) { pulsing = false }
                }
            }
            .accessibilityHidden(true)
    }

    private func startPulseIfRunning() {
        guard state == .running, !pulsing else { return }
        withAnimation(UnifiedDesignSystem.Animation.mercuryPulse) { pulsing = true }
    }
}
