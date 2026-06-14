import SwiftUI
import OpenBurnBarCore

// remediation(hermes-decomposition): relocated verbatim from HermesTabView.swift
// to shrink that god-file. This is the self-contained Hermes connection/status
// widget family — the rotating globe / model / refresh badge shown in the chat
// runtime rail. `ProviderStatusGlobeView`, `BreathingDot`,
// `HermesDynamicStatusWidget`, and `SpinningRefreshIcon` only ever reference
// each other and module-/Core-level symbols, so the move is behavior-preserving.
// Access was widened from `private` to internal (module-visible) so the widget
// stays reachable from `HermesChatView`'s runtime rail in the same module.

// MARK: - Provider Status Globe View

struct ProviderStatusGlobeView: View {
    let provider: AgentProvider
    let isReachable: Bool
    let size: CGFloat = 24

    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var animateGlow = false

    var body: some View {
        ZStack {
            // Animated Glow Background (Perfectly Centered)
            Circle()
                .fill((isReachable ? DesignSystemColors.primary(for: provider) : DesignSystemColors.error).opacity(0.2))
                .frame(width: size * 1.4, height: size * 1.4)
                .scaleEffect(shouldAnimateGlow && animateGlow ? 1.25 : 0.85)
                .blur(radius: 2)
                .animation(
                    .easeInOut(duration: 1.8)
                    .repeatForever(autoreverses: true),
                    value: animateGlow
                )

            // Globe icon with provider or offline color gradient (Perfectly Centered)
            Image(systemName: "globe")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: isReachable ? [
                            DesignSystemColors.primary(for: provider),
                            DesignSystemColors.accent(for: provider)
                        ] : [
                            DesignSystemColors.error,
                            DesignSystemColors.error.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(
                    color: (isReachable ? DesignSystemColors.primary(for: provider) : DesignSystemColors.error).opacity(0.45),
                    radius: isReachable ? 4 : 1,
                    x: 0,
                    y: 1
                )
                .overlay(
                    // Status Indicator Badge at bottom trailing of the globe, offset outward
                    Circle()
                        .fill(isReachable ? MobileTheme.success : MobileTheme.warning)
                        .frame(width: size * 0.38, height: size * 0.38)
                        .overlay(
                            Circle()
                                .stroke(MobileTheme.Colors.background, lineWidth: 1.2)
                        )
                        .modifier(BreathingDot(active: isReachable))
                        .offset(x: 2.5, y: 2.5),
                    alignment: .bottomTrailing
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            animateGlow = shouldAnimateGlow
        }
        .onChange(of: shouldAnimateGlow) { _, shouldAnimate in
            animateGlow = shouldAnimate
        }
    }

    private var shouldAnimateGlow: Bool {
        MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }
}

// MARK: - Breathing Dot

struct BreathingDot: ViewModifier {
    let active: Bool
    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shouldAnimate && phase ? 1.5 : 1.0)
            .opacity(shouldAnimate && phase ? 0.55 : 1.0)
            .animation(shouldAnimate ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { phase = shouldAnimate }
            .onChange(of: shouldAnimate) { _, shouldAnimate in
                phase = shouldAnimate
            }
    }

    private var shouldAnimate: Bool {
        active && MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }
}

// MARK: - Dynamic Status Widget

struct HermesDynamicStatusWidget: View {
    let provider: AgentProvider
    let isReachable: Bool
    let isRefreshing: Bool
    let refreshAction: () -> Void

    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeState: WidgetState = .globe
    @State private var animateGlow = false

    enum WidgetState: Int, CaseIterable {
        case globe
        case model
        case refresh

        func next(isRefreshing: Bool) -> WidgetState {
            switch self {
            case .globe:
                return .model
            case .model:
                return isRefreshing ? .refresh : .globe
            case .refresh:
                return .globe
            }
        }
    }

    private var stateBorderColors: [Color] {
        if !isReachable {
            return [DesignSystemColors.error.opacity(0.48), DesignSystemColors.error.opacity(0.18)]
        }
        switch activeState {
        case .globe:
            return [
                DesignSystemColors.primary(for: provider).opacity(0.45),
                DesignSystemColors.accent(for: provider).opacity(0.2)
            ]
        case .model:
            return [
                DesignSystemColors.primary(for: provider).opacity(0.45),
                DesignSystemColors.accent(for: provider).opacity(0.2)
            ]
        case .refresh:
            return [
                MobileTheme.hermesAureate.opacity(0.6),
                MobileTheme.hermesAureate.opacity(0.24)
            ]
        }
    }

    private var stateShadowColor: Color {
        if !isReachable {
            return DesignSystemColors.error.opacity(0.35)
        }
        switch activeState {
        case .globe:
            return DesignSystemColors.primary(for: provider).opacity(0.25)
        case .model:
            return DesignSystemColors.primary(for: provider).opacity(0.25)
        case .refresh:
            return MobileTheme.hermesAureate.opacity(0.25)
        }
    }

    var body: some View {
        ZStack {
            if activeState == .globe {
                ProviderStatusGlobeView(provider: provider, isReachable: isReachable)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.75)),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.75))
                    ))
            } else if activeState == .model {
                modelBadge
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.75)),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.75))
                    ))
            } else {
                refreshBadge
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.75)),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.75))
                    ))
            }
        }
        .frame(width: 34, height: 34)
        .background(
            Circle()
                .fill(MobileTheme.Colors.surface.opacity(0.65))
                .shadow(color: stateShadowColor, radius: 4, x: 0, y: 0.8)
        )
        .overlay(
            Circle()
                .stroke(
                    LinearGradient(
                        colors: stateBorderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        )
        .onAppear {
            if isRefreshing {
                activeState = .refresh
            }
        }
        .task(id: statusWidgetTickerKey) { await runStatusWidgetTicker() }
        .onChange(of: shouldUpdateStatusWidget) { _, shouldUpdate in
            animateGlow = shouldUpdate
        }
        .onChange(of: isRefreshing) { _, refreshing in
            if refreshing {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    activeState = .refresh
                }
            } else {
                if activeState == .refresh {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                        activeState = .globe
                    }
                }
            }
        }
    }

    private var shouldUpdateStatusWidget: Bool {
        MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }

    private var statusWidgetTickerKey: String {
        "\(shouldUpdateStatusWidget)-\(isRefreshing)"
    }

    private func runStatusWidgetTicker() async {
        guard shouldUpdateStatusWidget else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, shouldUpdateStatusWidget else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.76, blendDuration: 0)) {
                    activeState = activeState.next(isRefreshing: isRefreshing)
                }
            }
        }
    }

    private var modelBadge: some View {
        ZStack {
            // Pulse glow for model
            Circle()
                .fill(
                    (isReachable ? DesignSystemColors.primary(for: provider) : DesignSystemColors.error)
                        .opacity(0.15)
                )
                .frame(width: 28, height: 28)
                .scaleEffect(animateGlow ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: animateGlow)
                .onAppear { animateGlow = shouldUpdateStatusWidget }

            UnifiedProviderLogoView(provider: provider, size: 20, useFallbackColor: true)
                .grayscale(isReachable ? 0.0 : 0.6)
                .opacity(isReachable ? 1.0 : 0.65)
        }
    }

    private var refreshBadge: some View {
        ZStack {
            Circle()
                .fill(MobileTheme.hermesAureate.opacity(0.12))
                .frame(width: 28, height: 28)
                .scaleEffect(animateGlow ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: animateGlow)
                .onAppear { animateGlow = shouldUpdateStatusWidget }

            SpinningRefreshIcon(isRefreshing: isRefreshing)
        }
    }
}

struct SpinningRefreshIcon: View {
    let isRefreshing: Bool
    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var spinDegree = 0.0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(MobileTheme.hermesAureate)
            .rotationEffect(.degrees(spinDegree))
            .id(shouldSpin)
            .onAppear { syncSpinState() }
            .onChange(of: shouldSpin) { _, _ in
                syncSpinState()
            }
    }

    private var shouldSpin: Bool {
        isRefreshing && MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }

    private func syncSpinState() {
        guard shouldSpin else {
            spinDegree = 0.0
            return
        }
        spinDegree = 0.0
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            spinDegree = 360.0
        }
    }
}
