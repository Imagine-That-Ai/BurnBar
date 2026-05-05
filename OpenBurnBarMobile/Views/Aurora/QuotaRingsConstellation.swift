import SwiftUI
import OpenBurnBarCore

// MARK: - Quota Rings Constellation
//
// 3D-tilted ring cluster — one ring per provider, plus a central "fleet"
// score. The plane parallaxes with device tilt for depth. Tap a ring to
// drill into per-provider quota.

struct QuotaRingsConstellation: View {
    struct Item: Identifiable, Hashable {
        let provider: AgentProvider
        let providerKey: String
        let pressureRemaining: Double  // 0...1 (0 = depleted, 1 = healthy)
        let label: String
        var id: String { providerKey }
    }

    let items: [Item]
    let onSelect: (Item) -> Void

    @Environment(\.motionStore) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) * 0.36
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                // Central fleet ring
                fleetRing
                    .position(center)

                // Provider rings on tilted orbital plane
                ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, item in
                    let theta = ringAngle(for: index, count: min(items.count, 8))
                    let position = ringPosition(center: center, radius: radius, angle: theta)
                    Button {
                        onSelect(item)
                        HapticBus.sheetOpen()
                    } label: {
                        providerRing(for: item)
                    }
                    .buttonStyle(.plain)
                    .position(position)
                }
            }
            // Subtle, static perspective only — the previous live tilt
            // (driven at 30Hz by CoreMotion with a 6× multiplier) caused
            // the ring cluster to oscillate and reposition wildly with
            // any hand movement.
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : 8),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.5
            )
        }
        .aspectRatio(1.6, contentMode: .fit)
    }

    // MARK: - Geometry

    private func ringAngle(for index: Int, count: Int) -> Double {
        let stride = (2.0 * .pi) / Double(count)
        return -.pi / 2 + Double(index) * stride
    }

    private func ringPosition(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        // Squash y to suggest perspective
        let x = center.x + cos(angle) * radius
        let y = center.y + sin(angle) * radius * 0.55
        return CGPoint(x: x, y: y)
    }

    // MARK: - Fleet Ring

    private var fleetRing: some View {
        let avg = items.isEmpty ? 1.0 :
            items.map(\.pressureRemaining).reduce(0, +) / Double(items.count)
        let pct = max(0, min(1, avg))
        return ZStack {
            Circle()
                .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 6)
                .frame(width: 110, height: 110)
            Circle()
                .trim(from: 0, to: CGFloat(pct))
                .stroke(
                    AngularGradient(
                        colors: [
                            MobileTheme.success,
                            MobileTheme.amber,
                            MobileTheme.ember,
                            MobileTheme.success
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 110, height: 110)
                .shadow(color: MobileTheme.amber.opacity(0.55), radius: 12)

            VStack(spacing: 2) {
                Text("FLEET")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(2)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .contentTransition(.numericText())
                Text("healthy")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Provider Ring

    @ViewBuilder
    private func providerRing(for item: Item) -> some View {
        let primary = MobileTheme.Colors.primary(for: item.provider)
        let pct = CGFloat(max(0, min(1, item.pressureRemaining)))
        ZStack {
            Circle()
                .stroke(primary.opacity(0.18), lineWidth: 4)
                .frame(width: 64, height: 64)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 64, height: 64)
                .shadow(color: primary.opacity(0.6), radius: 10)
            UnifiedProviderLogoView(provider: item.provider, size: 22, useFallbackColor: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.provider.displayName), \(Int(pct * 100)) percent remaining")
    }
}
