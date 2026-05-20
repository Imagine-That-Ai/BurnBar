import AppKit
import SwiftUI

// MARK: - Dashboard Depth Backdrop (macOS)
//
// Secondary aurora layer that sits behind the macOS Dashboard scroll so the
// page reads as a layered scene instead of a flat plate of cards. Keep this
// static: the dashboard lives in a status-item app, and continuously animating
// large blurred shapes can monopolize SwiftUI layout/rendering while the user
// is just trying to bring the window forward.
//
// Decorative only — `allowsHitTesting(false)` everywhere. Respects Reduce
// Transparency by lowering the tint layer opacity.

struct DashboardDepthBackdrop: View {

    var density: Density = .full

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    enum Density { case full, subtle }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                DesignSystem.Colors.background

                Rectangle()
                    .fill(DesignSystem.Colors.ember.opacity(density == .full ? 0.055 : 0.035))
                    .frame(width: max(w * 0.50, 420), height: h * 1.3)
                    .rotationEffect(.degrees(-13))
                    .offset(x: -w * 0.30, y: -h * 0.08)

                Rectangle()
                    .fill(DesignSystem.Colors.whimsy.opacity(density == .full ? 0.045 : 0.025))
                    .frame(width: max(w * 0.44, 360), height: h * 1.2)
                    .rotationEffect(.degrees(17))
                    .offset(x: w * 0.34, y: h * 0.10)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .opacity(reduceTransparency ? 0.35 : 1.0)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}
