import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Atom Components (macOS)
//
// Mirrors `OpenBurnBarMobile`'s atom layer, but uses macOS-native idioms:
//   - `HermesAtomChip` — same atomic chip behaviour, styled with
//     `DesignSystem` tokens.
//   - `HermesAtomRouter` — `@Observable` router with a `pending` slot the
//     chat view binds to a popover or sheet.
//   - `HermesRichBubble` — parses an assistant message with `HermesAtomParser`,
//     lays out via `PretextEngine.prepareRichInline`, renders body / mention /
//     code / atom fragments natively.
//   - `StreamingBubble` — measures the in-flight assistant text via Pretext,
//     animates its frame height, runs shrink-wrap when streaming finishes.
//   - `HermesAtomDetailPopover` — hosted inside the chat panel, presented as
//     a popover from the chip on tap. Compact, single-action.
//
// Sharing a file in macOS is fine — these views are tightly related and
// AgentLens already groups Chat code under one folder. Keep iOS components
// in a separate file (lives in OpenBurnBarMobile/Views/Components/).

// MARK: - Environment

private struct MacHermesAtomNavigatorKey: EnvironmentKey {
    static let defaultValue: any HermesAtomNavigator = NoopHermesAtomNavigator()
}

extension EnvironmentValues {
    var hermesAtomNavigator: any HermesAtomNavigator {
        get { self[MacHermesAtomNavigatorKey.self] }
        set { self[MacHermesAtomNavigatorKey.self] = newValue }
    }
}

// MARK: - Router
//
// Mirrors the iOS router behaviour. `open(_:)` sets a `pending` slot the
// chat surface binds to `.popover(item:)`. `confirm(_:)` updates
// `confirmedDestination`, calls `onPerform`, and broadcasts a
// notification so ambient routes (sidebar, settings panel) can handle the
// activation without the chat surface owning all destinations.

@MainActor
@Observable
final class HermesAtomRouter: HermesAtomNavigator {
    var pending: PendingAtom?
    var confirmedDestination: HermesAtomDestination?

    /// Optional caller-supplied destination handler. Installed by the chat
    /// surface; called on the main actor when the user confirms a chip.
    var onPerform: ((HermesAtom) -> Void)?

    init() {}

    func open(_ atom: HermesAtom) {
        pending = PendingAtom(atom: atom, label: atom.fallbackLabel)
    }

    func confirm(_ pending: PendingAtom) {
        let destination = HermesAtomDestination(atom: pending.atom)
        confirmedDestination = destination
        onPerform?(pending.atom)
        NotificationCenter.default.post(
            name: .hermesAtomActivated,
            object: nil,
            userInfo: [HermesAtomNotificationKey.atom: pending.atom]
        )
    }

    struct PendingAtom: Identifiable, Hashable {
        let atom: HermesAtom
        let label: String
        var id: HermesAtom { atom }
    }
}

struct HermesAtomDestination: Equatable, Hashable {
    let atom: HermesAtom
}

// MARK: - Notification Bridge

extension Notification.Name {
    /// Posted by `HermesAtomRouter.confirm(_:)`. Subscribers (sidebar,
    /// settings, dashboard) can listen to dispatch navigation without
    /// coupling chat surfaces to specific destinations.
    static let hermesAtomActivated = Notification.Name("hermesAtomActivated")
}

enum HermesAtomNotificationKey {
    /// `userInfo` key carrying the activated `HermesAtom`.
    static let atom = "atom"
}

// MARK: - Atom Chip

struct HermesAtomChip: View {
    let atom: HermesAtom
    let label: String
    var size: ChipSize

    @Environment(\.hermesAtomNavigator) private var navigator
    @State private var isHovering = false

    enum ChipSize: Equatable {
        case inline(baseSize: CGFloat)
        case standalone

        var fontSize: CGFloat {
            switch self {
            case .inline(let base): return max(11, base - 1)
            case .standalone: return 13
            }
        }
        var iconSize: CGFloat {
            switch self {
            case .inline(let base): return max(9, base - 4)
            case .standalone: return 11
            }
        }
        var horizontalPadding: CGFloat {
            switch self {
            case .inline: return 7
            case .standalone: return 10
            }
        }
        var verticalPadding: CGFloat {
            switch self {
            case .inline: return 1.5
            case .standalone: return 5
            }
        }
        var cornerRadius: CGFloat {
            switch self {
            case .inline: return 7
            case .standalone: return 9
            }
        }
    }

    init(atom: HermesAtom, label: String, size: ChipSize = .standalone) {
        self.atom = atom
        self.label = label
        self.size = size
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 4) {
                Image(systemName: atom.kind.systemImage)
                    .font(.system(size: size.iconSize, weight: .bold))
                Text(label)
                    .font(.system(size: size.fontSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(accent.opacity(isHovering ? 0.20 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .stroke(accent.opacity(isHovering ? 0.55 : 0.32), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(atom.kind.description)
        .accessibilityLabel("\(atom.kind.categoryLabel): \(label)")
        .accessibilityHint(atom.kind.description)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            isHovering = hovering
            #if os(macOS)
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
            #endif
        }
    }

    private func tap() {
        navigator.open(atom)
    }

    private var accent: Color {
        switch atom.kind {
        case .cost:     return DesignSystem.Colors.amber
        case .session:  return DesignSystem.Colors.hermesAureate
        case .provider: return DesignSystem.Colors.ember
        case .model:    return DesignSystem.Colors.whimsy
        case .window:   return DesignSystem.Colors.hermesAureate
        case .tool:     return DesignSystem.Colors.blaze
        case .project:  return DesignSystem.Colors.amber
        case .tokens:   return DesignSystem.Colors.success
        case .quota:    return DesignSystem.Colors.warning
        case .runtime:  return DesignSystem.Colors.hermesAureate
        }
    }
}

// MARK: - Detail Popover Content

struct HermesAtomDetailPopover: View {
    let atom: HermesAtom
    let label: String
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: atom.kind.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(atom.kind.categoryLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(label)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Text(atom.kind.description)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .background(DesignSystem.Colors.border)

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(actionLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var actionLabel: String {
        switch atom {
        case .cost(_, let window):
            return "Open \(window.displayLabel) burn"
        case .session:                return "Open session"
        case .provider(let token):    return "Open \(token.capitalized)"
        case .model(let id):          return "Use \(id)"
        case .window(let value):      return "Switch to \(value.displayLabel)"
        case .tool(let name):         return "Find \(name) in run"
        case .project(let id):        return "Open project \(id)"
        case .tokens:                 return "Open token detail"
        case .quota(let provider, _): return "Open \(provider.capitalized) quota"
        case .runtime(let profile):   return "Open \(profile.capitalized) runtime"
        }
    }

    private var accent: Color {
        switch atom.kind {
        case .cost:     return DesignSystem.Colors.amber
        case .session:  return DesignSystem.Colors.hermesAureate
        case .provider: return DesignSystem.Colors.ember
        case .model:    return DesignSystem.Colors.whimsy
        case .window:   return DesignSystem.Colors.hermesAureate
        case .tool:     return DesignSystem.Colors.blaze
        case .project:  return DesignSystem.Colors.amber
        case .tokens:   return DesignSystem.Colors.success
        case .quota:    return DesignSystem.Colors.warning
        case .runtime:  return DesignSystem.Colors.hermesAureate
        }
    }
}

// MARK: - Rich Bubble (macOS)

struct HermesRichBubble: View {
    let text: String
    var baseSize: CGFloat = 14
    var baseColor: Color = DesignSystem.Colors.textPrimary
    var mentionColor: Color = DesignSystem.Colors.hermesAureate
    var codeColor: Color = DesignSystem.Colors.textPrimary
    var codeBackground: Color = DesignSystem.Colors.surfaceElevated
    var lineHeight: CGFloat?

    @State private var runs: [HermesRichRun] = []
    @State private var lines: [PretextRichLine] = []

    private var resolvedLineHeight: CGFloat {
        lineHeight ?? (baseSize * 1.36)
    }

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .frame(height: estimatedHeight)
    }

    private var estimatedHeight: CGFloat {
        let count = max(lines.count, fallbackLineEstimate)
        return CGFloat(count) * resolvedLineHeight
    }

    private var fallbackLineEstimate: Int {
        max(1, Int((Double(text.count) / 60.0).rounded(.up)))
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if lines.isEmpty {
            attributedFallback(width: width)
                .task(id: measureKey(width: width)) { await measure(at: width) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(Array(line.fragments.enumerated()), id: \.offset) { _, fragment in
                            renderedFragment(fragment)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: resolvedLineHeight, alignment: .leading)
                    .frame(maxWidth: width, alignment: .leading)
                }
            }
            .frame(maxWidth: width, alignment: .leading)
            .task(id: measureKey(width: width)) { await measure(at: width) }
        }
    }

    @ViewBuilder
    private func renderedFragment(_ fragment: PretextRichFragment) -> some View {
        if fragment.itemIndex < runs.count {
            let run = runs[fragment.itemIndex]
            switch run.kind {
            case .body:
                Text(fragment.text)
                    .font(.system(size: baseSize, design: .rounded))
                    .foregroundStyle(baseColor)
                    .padding(.leading, fragment.gapBefore)
            case .atom(let atom, let label):
                HermesAtomChip(atom: atom, label: label, size: .inline(baseSize: baseSize))
                    .padding(.leading, fragment.gapBefore)
            case .mention(let handle):
                Text(handle)
                    .font(.system(size: baseSize - 1, weight: .semibold, design: .rounded))
                    .foregroundStyle(mentionColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(mentionColor.opacity(0.12))
                    )
                    .padding(.leading, fragment.gapBefore)
            case .code:
                Text(fragment.text)
                    .font(.system(size: baseSize - 1, weight: .medium, design: .monospaced))
                    .foregroundStyle(codeColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(codeBackground.opacity(0.85))
                    )
                    .padding(.leading, fragment.gapBefore)
            }
        } else {
            Text(fragment.text)
                .font(.system(size: baseSize, design: .rounded))
                .foregroundStyle(baseColor)
                .padding(.leading, fragment.gapBefore)
        }
    }

    @ViewBuilder
    private func attributedFallback(width: CGFloat) -> some View {
        Text(buildAttributedFallback())
            .font(.system(size: baseSize, design: .rounded))
            .foregroundStyle(baseColor)
            .frame(maxWidth: width, alignment: .leading)
            .lineSpacing(max(0, resolvedLineHeight - baseSize - 4))
    }

    private func buildAttributedFallback() -> AttributedString {
        let parsed = HermesAtomParser.parse(text)
        var attr = AttributedString()
        for run in parsed {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .body:
                piece.foregroundColor = baseColor
            case .atom:
                piece.foregroundColor = DesignSystem.Colors.hermesAureate
                piece.font = .system(size: baseSize - 1, weight: .semibold, design: .rounded)
            case .mention:
                piece.foregroundColor = mentionColor
                piece.font = .system(size: baseSize - 1, weight: .semibold, design: .rounded)
            case .code:
                piece.foregroundColor = codeColor
                piece.font = .system(size: baseSize - 1, weight: .medium, design: .monospaced)
            }
            attr.append(piece)
        }
        return attr
    }

    private func measureKey(width: CGFloat) -> String {
        "\(text.hashValue)|\(baseSize)|\(width)|\(resolvedLineHeight)"
    }

    private func measure(at width: CGFloat) async {
        guard width > 0, !text.isEmpty else { return }
        let parsed = HermesAtomParser.parse(text)
        let items = parsed.map { Self.toPretextItem($0, baseSize: baseSize) }
        guard !items.isEmpty else { return }
        do {
            let engine = PretextEngine.shared
            let handle = try await engine.prepareRichInline(items: items)
            let resolved = try await engine.layoutRichInline(handle: handle, maxWidth: width)
            await engine.release(handle: handle)
            await MainActor.run {
                self.runs = parsed
                self.lines = resolved
            }
        } catch {
            // Engine unavailable — keep fallback text rendered.
        }
    }

    private static func toPretextItem(
        _ run: HermesRichRun,
        baseSize: CGFloat
    ) -> PretextRichInlineItem {
        switch run.kind {
        case .body:
            return PretextRichInlineItem(
                text: run.text,
                font: "400 \(Int(baseSize))px -apple-system"
            )
        case .atom:
            return PretextRichInlineItem(
                text: run.text,
                font: "600 \(Int(max(11, baseSize - 1)))px -apple-system",
                breakNever: true,
                extraWidth: 14 + 12 + 4
            )
        case .mention:
            return PretextRichInlineItem(
                text: run.text,
                font: "600 \(Int(baseSize - 1))px -apple-system",
                breakNever: true,
                extraWidth: 12
            )
        case .code:
            return PretextRichInlineItem(
                text: run.text,
                font: "500 \(Int(baseSize - 1))px ui-monospace, Menlo, monospace",
                extraWidth: 10
            )
        }
    }
}

// MARK: - Streaming Bubble (macOS)

struct StreamingBubble<Content: View>: View {
    let text: String
    let isStreaming: Bool
    let isError: Bool
    let baseSize: CGFloat
    let lineHeight: CGFloat
    let shrinkTargetLines: Int
    @ViewBuilder var content: () -> Content

    init(
        text: String,
        isStreaming: Bool,
        isError: Bool,
        baseSize: CGFloat = 14,
        lineHeight: CGFloat = 20,
        shrinkTargetLines: Int = 4,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.isError = isError
        self.baseSize = baseSize
        self.lineHeight = lineHeight
        self.shrinkTargetLines = shrinkTargetLines
        self.content = content
    }

    @State private var measuredHeight: CGFloat? = nil
    @State private var measuredWidth: CGFloat? = nil

    var body: some View {
        GeometryReader { proxy in
            content()
                .frame(maxWidth: measuredWidth ?? proxy.size.width, alignment: .leading)
                .task(id: trigger(width: proxy.size.width)) {
                    await measure(at: proxy.size.width)
                }
        }
        .frame(height: measuredHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: measuredHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: measuredWidth)
    }

    private func trigger(width: CGFloat) -> String {
        let bucket = isStreaming ? text.count / 32 : -1
        return "\(text.hashValue)|\(width)|\(isStreaming ? 1 : 0)|\(isError ? 1 : 0)|\(bucket)"
    }

    private func measure(at width: CGFloat) async {
        guard width > 0, !text.isEmpty else { return }
        let canvasFont = "400 \(Int(baseSize))px -apple-system"
        do {
            let engine = PretextEngine.shared
            let prepared = try await engine.prepare(text: text, font: canvasFont)
            let layout = try await engine.layout(handle: prepared, maxWidth: width, lineHeight: lineHeight)
            await MainActor.run {
                self.measuredHeight = layout.height
            }
            if !isStreaming && !isError {
                let preparedSegments = try await engine.prepareWithSegments(text: text, font: canvasFont)
                let tightest = try await engine.shrinkWrapWidth(
                    handle: preparedSegments,
                    upper: width,
                    targetLines: shrinkTargetLines
                )
                let final = try await engine.layoutWithLines(handle: preparedSegments, maxWidth: tightest, lineHeight: lineHeight)
                await MainActor.run {
                    self.measuredWidth = tightest
                    self.measuredHeight = final.height
                }
            } else if isStreaming {
                await MainActor.run {
                    self.measuredWidth = nil
                }
            }
        } catch {
            // Engine unavailable — let SwiftUI auto-size content().
        }
    }
}
