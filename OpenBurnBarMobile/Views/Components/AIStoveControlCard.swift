import SwiftUI
import OpenBurnBarCore

// MARK: - Stove Level definition

struct StoveLevel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let concurrency: Int
    let temperature: Double
    let description: String
    let flameCount: Int
    let flameScale: CGFloat
    let pulseDuration: Double
}

struct AIStoveControlCard: View {
    @AppStorage("aiStoveHeatLevel") private var selectedLevel: String = "Mix"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiMode) private var uiMode

    private let levels = [
        StoveLevel(
            id: "Stir",
            displayName: "Stir",
            concurrency: 1,
            temperature: 0.3,
            description: "Slow-stirring single-agent queries. Best for coconut-smooth code formatting and light analysis.",
            flameCount: 6,
            flameScale: 0.6,
            pulseDuration: 1.8
        ),
        StoveLevel(
            id: "Mix",
            displayName: "Mix",
            concurrency: 2,
            temperature: 0.5,
            description: "Balanced kiwi-and-banana mixing speed for quick, precise edits. Best for day-to-day coding refactors.",
            flameCount: 12,
            flameScale: 0.8,
            pulseDuration: 1.4
        ),
        StoveLevel(
            id: "Whirl",
            displayName: "Whirl",
            concurrency: 4,
            temperature: 0.7,
            description: "High-velocity smoothie whirl of parallel reasoning. Great for multi-file generation and deep context lookup.",
            flameCount: 16,
            flameScale: 1.0,
            pulseDuration: 1.0
        ),
        StoveLevel(
            id: "Crush",
            displayName: "Crush",
            concurrency: 6,
            temperature: 0.8,
            description: "Ultra-intense tropical ice crushing. Parallel swarm of complex algorithmic tasks.",
            flameCount: 20,
            flameScale: 1.25,
            pulseDuration: 0.7
        ),
        StoveLevel(
            id: "Turbo",
            displayName: "Turbo",
            concurrency: 10,
            temperature: 1.0,
            description: "Maximum turbo pitaya blending power. Blending the ocean of deep repository refactoring.",
            flameCount: 28,
            flameScale: 1.5,
            pulseDuration: 0.4
        )
    ]

    private var currentLevel: StoveLevel {
        levels.first(where: { $0.id == selectedLevel }) ?? levels[1]
    }

    var body: some View {
        let theme = UIModeTheme(mode: uiMode)

        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Juice Blender")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(theme.textPrimary)
                        Text("Active Blender Concurrency")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()

                    // Sparkles indicator
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [theme.primaryAccent, theme.secondaryAccent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .scaleEffect(1.0 + CGFloat(levels.firstIndex(of: currentLevel) ?? 1) * 0.08)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedLevel)
                }

                // Main card content: left stats, right burner graphic
                HStack(spacing: MobileTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                        // Current stats pill
                        HStack(spacing: 8) {
                            statBadge(label: "Concurrency", value: "\(currentLevel.concurrency)x", theme: theme)
                            statBadge(label: "Temp", value: String(format: "%.1f", currentLevel.temperature), theme: theme)
                        }

                        Text(currentLevel.description)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(4)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 8)

                    // Stove Burner Visualizer
                    ZStack {
                        // Outer burner chassis
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [theme.border.opacity(0.4), theme.border.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2.5
                            )
                            .frame(width: 84, height: 84)

                        // Inner glowing element
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        theme.primaryAccent.opacity(0.18 + Double(currentLevel.flameScale) * 0.05),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 36
                                )
                            )
                            .frame(width: 72, height: 72)

                        // Center metallic cap
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.08),
                                        theme.border.opacity(0.15),
                                        Color.black.opacity(0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle()
                                    .stroke(theme.border.opacity(0.3), lineWidth: 0.5)
                            )

                        // Glowing flame jets emerging radially
                        ZStack {
                            ForEach(0..<currentLevel.flameCount, id: \.self) { idx in
                                let angle = Double(idx) * (360.0 / Double(currentLevel.flameCount))
                                FlameJetView(theme: theme, level: currentLevel)
                                    .rotationEffect(.degrees(angle))
                            }
                        }
                        .id(currentLevel.id)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    .frame(width: 90, height: 90)
                }

                // Premium sliding selection track
                GeometryReader { geo in
                    let trackWidth = geo.size.width
                    let itemWidth = trackWidth / CGFloat(levels.count)
                    let selectedIndex = levels.firstIndex(of: currentLevel) ?? 1

                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surface.opacity(colorScheme == .dark ? 0.3 : 0.6))
                            .frame(height: 38)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.border.opacity(0.2), lineWidth: 0.5)
                            )

                        // Sliding selection indicator
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.primaryAccent, theme.primaryAccent.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: itemWidth - 4, height: 34)
                            .offset(x: itemWidth * CGFloat(selectedIndex) + 2)
                            .shadow(color: theme.primaryAccent.opacity(0.3), radius: 3, y: 1)

                        // Mode text button overlays
                        HStack(spacing: 0) {
                            ForEach(0..<levels.count, id: \.self) { idx in
                                let level = levels[idx]
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                        selectedLevel = level.id
                                    }
                                    Haptics.light()
                                } label: {
                                    Text(level.displayName)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(selectedLevel == level.id ? Color.white : theme.textSecondary)
                                        .frame(width: itemWidth, height: 38)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 38)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func statBadge(label: String, value: String, theme: UIModeTheme) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textSecondary.opacity(0.8))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryAccent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.primaryAccent.opacity(0.08))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.primaryAccent.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - FlameJetView

struct FlameJetView: View {
    let theme: UIModeTheme
    let level: StoveLevel
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack {
            // The capsule represents the gas flame jet with color shift (blue base to yellow to orange)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryAccent, // Sriracha orange/red tip
                            theme.secondaryAccent.opacity(0.9), // Lemon gold body
                            Color(hex: "00E5FF").opacity(0.95)  // Glowing gas cyan base
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3.5 * level.flameScale, height: 13 * level.flameScale)
                .scaleEffect(scale)
                .shadow(color: theme.primaryAccent.opacity(0.5), radius: 2)
                .offset(y: -30 - CGFloat(level.flameScale * 2)) // push outward based on level scale
            Spacer()
        }
        .frame(width: 8, height: 86)
        .onAppear {
            withAnimation(
                .easeInOut(duration: level.pulseDuration)
                .repeatForever()
                .delay(Double.random(in: 0...0.3))
            ) {
                scale = 1.25
            }
        }
    }
}

#Preview {
    AIStoveControlCard()
        .padding()
        .background(Color.black.ignoresSafeArea())
        .environment(\.uiMode, .cooking)
}
