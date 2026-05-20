import SwiftUI

// MARK: - ASCII / Unicode-block Canvas
//
// A renderer for the new `ascii` Chart Studio kind. Inspired by:
//
// - Hermes' `ascii-art` and `architecture-diagram` skills (terminal-native
//   visual output).
// - OpenTUI by Chang Lou (former Midjourney engineer) — Zig core +
//   TypeScript bindings for terminal UIs that lean on box-drawing and
//   half-block characters (▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉ ╭╮╯╰─│) for crisp,
//   monospace-aligned data viz inside a TTY.
//
// We render Hermes-supplied monospace blocks inside a glassy terminal
// frame with a synthetic chrome bar (traffic-light dots) so the output
// reads as a "screenshot of a TUI" rather than a generic preformatted
// dump. SF Mono ensures the box-drawing characters align to a uniform
// cell grid the way they would on a real terminal.

struct AsciiCanvasView: View {
    let spec: AsciiSpec

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretPhase: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            terminalFrame {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(spec.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                    promptCaret
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if let footnote = spec.footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { animateCaret() }
    }

    // MARK: - Terminal chrome

    @ViewBuilder
    private func terminalFrame<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Chrome bar with traffic-light dots + pseudo-tab.
            HStack(spacing: 8) {
                Circle().fill(Color(red: 0.95, green: 0.36, blue: 0.36)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.95, green: 0.71, blue: 0.30)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.36, green: 0.84, blue: 0.43)).frame(width: 10, height: 10)
                Spacer()
                Text(spec.variant.tabLabel)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(MobileTheme.Colors.surface.opacity(0.6))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.55),
                        Color.black.opacity(0.40)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MobileTheme.Colors.borderSubtle.opacity(0.5))
                    .frame(height: 0.5)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .frame(minWidth: 0, alignment: .leading)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.62),
                        Color.black.opacity(0.50)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            MobileTheme.hermesAureate.opacity(0.55),
                            MobileTheme.hermesAureate.opacity(0.20)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    // MARK: - One block

    @ViewBuilder
    private func blockView(_ block: AsciiSpec.Block) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = block.label, !label.isEmpty {
                HStack(spacing: 6) {
                    Text("▎")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(accentColor(for: block))
                    Text(label.uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(MobileTheme.Colors.textSecondary.opacity(0.85))
                }
                .padding(.bottom, 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(lineColor(for: line, block: block))
                        .lineSpacing(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var promptCaret: some View {
        HStack(spacing: 0) {
            Text("hermes ❯ ")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(MobileTheme.hermesAureate)
            Text("█")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(MobileTheme.hermesAureate.opacity(0.45 + 0.55 * caretPhase))
        }
    }

    private func animateCaret() {
        guard !reduceMotion else {
            caretPhase = 1
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            caretPhase = 1
        }
    }

    // MARK: - Color helpers

    private func accentColor(for block: AsciiSpec.Block) -> Color {
        if let hex = block.accent, let parsed = Color(asciiHex: hex) {
            return parsed
        }
        return MobileTheme.hermesAureate
    }

    /// Subtle palette: half-blocks/box-drawing characters get the block
    /// accent color, everything else stays terminal-cream so labels and
    /// numbers read cleanly.
    private func lineColor(for line: String, block: AsciiSpec.Block) -> Color {
        let blockChars: Set<Character> = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
                                          "▏", "▎", "▍", "▌", "▋", "▊", "▉",
                                          "░", "▒", "▓"]
        let frameChars: Set<Character> = ["╭", "╮", "╯", "╰", "─", "│", "├", "┤",
                                          "┬", "┴", "┼", "═", "║", "╔", "╗",
                                          "╚", "╝", "╠", "╣", "╦", "╩", "╬"]

        let blockHits = line.filter { blockChars.contains($0) }.count
        let frameHits = line.filter { frameChars.contains($0) }.count

        if blockHits >= 4 {
            return accentColor(for: block)
        }
        if frameHits >= 6 && blockHits == 0 {
            return MobileTheme.Colors.textMuted
        }
        return Color(red: 0.94, green: 0.92, blue: 0.86) // terminal cream
    }
}

private extension AsciiSpec.Variant {
    var tabLabel: String {
        switch self {
        case .bar:       return "tui · bars"
        case .sparkline: return "tui · sparks"
        case .heatmap:   return "tui · heat"
        case .banner:    return "tui · banner"
        case .scene:     return "tui · scene"
        }
    }
}

// MARK: - Hex helpers

private extension Color {
    /// Lenient `#RRGGBB` parser used by the AsciiSpec renderer.
    init?(asciiHex hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
