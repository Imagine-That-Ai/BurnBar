import SwiftUI

// MARK: - Chart Studio Floating Action Button
//
// Visible only when Studio is minimized. Sits above the Aurora nav tray,
// drag-to-reposition, tap to restore. Persists its position via
// `ChartStudioPresenter.fabOffset`.

struct ChartStudioFloatingButton: View {
    @Bindable var presenter: ChartStudioPresenter

    @State private var dragOffset: CGSize = .zero
    @State private var pulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fabSize: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let bounds = geo.size

            ZStack {
                if presenter.mode == .minimized {
                    fab
                        .frame(width: fabSize, height: fabSize)
                        .position(positionFor(bounds: bounds, safeArea: safeArea))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    // Snap to nearest edge horizontally; clamp
                                    // vertically so it stays above the nav.
                                    let newOffset = clampedOffset(
                                        candidate: CGSize(
                                            width: presenter.fabOffset.width + value.translation.width,
                                            height: presenter.fabOffset.height + value.translation.height
                                        ),
                                        bounds: bounds,
                                        safeArea: safeArea
                                    )
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        presenter.fabOffset = newOffset
                                        dragOffset = .zero
                                    }
                                }
                        )
                        .transition(
                            .scale(scale: 0.6).combined(with: .opacity)
                        )
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(presenter.mode == .minimized)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - The button itself

    private var fab: some View {
        Button {
            presenter.restore()
            HapticBus.send()
        } label: {
            ZStack {
                // Glow halo behind the bubble
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                MobileTheme.hermesAureate.opacity(0.55),
                                MobileTheme.hermesAureate.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: pulse ? 38 : 28
                        )
                    )
                    .frame(width: 92, height: 92)
                    .blur(radius: 8)
                    .opacity(pulse ? 0.95 : 0.6)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        MobileTheme.hermesMercury,
                                        MobileTheme.hermesAureate
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.0
                            )
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 5)

                HermesLiveGlyph(size: 26, isLive: false)
                    .shadow(color: MobileTheme.hermesAureate.opacity(0.5), radius: 6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restore Chart Studio")
    }

    // MARK: - Position math

    /// Resolved center point for the FAB given the current persisted offset
    /// + the live drag delta + safe-area + bounds clamping.
    private func positionFor(bounds: CGSize, safeArea: EdgeInsets) -> CGPoint {
        // Default anchor: bottom-right, just above the nav tray.
        let baseX = bounds.width - safeArea.trailing - fabSize / 2 - 16
        let baseY = bounds.height - safeArea.bottom - fabSize / 2 - 96
        let candidate = CGSize(
            width: presenter.fabOffset.width + dragOffset.width,
            height: presenter.fabOffset.height + dragOffset.height
        )
        let clamped = clampedOffset(candidate: candidate, bounds: bounds, safeArea: safeArea)
        return CGPoint(x: baseX + clamped.width, y: baseY + clamped.height)
    }

    private func clampedOffset(candidate: CGSize, bounds: CGSize, safeArea: EdgeInsets) -> CGSize {
        let baseX = bounds.width - safeArea.trailing - fabSize / 2 - 16
        let baseY = bounds.height - safeArea.bottom - fabSize / 2 - 96
        let resolvedX = baseX + candidate.width
        let resolvedY = baseY + candidate.height

        let minX = safeArea.leading + fabSize / 2 + 8
        let maxX = bounds.width - safeArea.trailing - fabSize / 2 - 8
        let minY = safeArea.top + fabSize / 2 + 60   // keep below status bar
        let maxY = bounds.height - safeArea.bottom - fabSize / 2 - 88   // keep above nav

        let clampedX = min(max(resolvedX, minX), maxX)
        let clampedY = min(max(resolvedY, minY), maxY)

        return CGSize(width: clampedX - baseX, height: clampedY - baseY)
    }
}
