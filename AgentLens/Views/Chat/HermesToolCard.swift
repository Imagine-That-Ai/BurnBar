import SwiftUI

// MARK: - Hermes Tool Card

/// Collapsible tool card for Hermes mode with mercury gradient stroke
/// and progressive disclosure. Each card tracks its own expansion state.
struct HermesToolCard: View {
    let toolName: String
    let detail: String?
    var isRunning: Bool

    @State private var isExpanded: Bool = false
    @State private var pulse: Bool = false

    private let shape = ChatBubbleStyle.toolShape()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header — always visible
            HStack(spacing: 6) {
                Image(systemName: capabilityIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.mercuryGradient)

                Text(toolName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.mercuryGradient)

                Spacer(minLength: 0)

                if isRunning {
                    shimmerDot
                } else if detail != nil && !detail!.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            // Running status
            if isRunning {
                Text("Running...")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            // Expanded detail
            if isExpanded && !isRunning, let detail, !detail.isEmpty {
                Text(detail)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.hermesMercury.opacity(0.08),
                            DesignSystem.Colors.hermesAureate.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
        .clipShape(shape)
        .overlay(
            shape
                .strokeBorder(DesignSystem.Colors.mercuryGradient, lineWidth: 1)
        )
        .mercuryShimmer(active: isRunning)
        .shadow(color: DesignSystem.Colors.hermesMercury.opacity(0.1), radius: 6, y: 2)
        .contentShape(shape)
        .onTapGesture {
            guard !isRunning else { return }
            withAnimation(DesignSystem.Animation.gentle) {
                isExpanded.toggle()
            }
        }
        .onChange(of: isRunning) { _, newRunning in
            if !newRunning {
                pulse = false
                withAnimation(DesignSystem.Animation.gentle) {
                    isExpanded = false
                }
            }
        }
        .animation(DesignSystem.Animation.gentle, value: isExpanded)
        .animation(DesignSystem.Animation.snappy, value: isRunning)
    }

    // MARK: - Shimmer Dot

    private var shimmerDot: some View {
        Circle()
            .fill(DesignSystem.Colors.mercuryGradient)
            .frame(width: 6, height: 6)
            .scaleEffect(pulse ? 1.2 : 0.8)
            .opacity(pulse ? 1 : 0.4)
            .onAppear {
                withAnimation(DesignSystem.Animation.mercuryPulse) {
                    pulse = true
                }
            }
    }

    // MARK: - Capability Icon

    private var capabilityIcon: String {
        let n = toolName.lowercased()
        if n.contains("read") || n.contains("file") || n.contains("write") { return "doc.text" }
        if n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") || n.contains("find") { return "magnifyingglass" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") || n.contains("http") { return "globe" }
        if n.contains("edit") || n.contains("patch") || n.contains("replace") { return "pencil.and.outline" }
        if n.contains("memory") || n.contains("skill") || n.contains("learn") { return "brain" }
        if n.contains("image") || n.contains("vision") || n.contains("screenshot") { return "photo" }
        if n.contains("tts") || n.contains("voice") || n.contains("speak") { return "waveform" }
        return "wrench.and.screwdriver"
    }
}

// MARK: - ChatBubbleStyle access

/// Re-expose toolShape for use in HermesToolCard.
/// Original lives in ChatMessageView.swift — copied here to avoid coupling.
private enum ChatBubbleStyle {
    static func toolShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 10,
            bottomLeadingRadius: 8,
            bottomTrailingRadius: 12,
            topTrailingRadius: 6,
            style: .continuous
        )
    }
}
