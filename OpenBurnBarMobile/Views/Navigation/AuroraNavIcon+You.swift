import SwiftUI

// MARK: - 5. You (Bust + Halo)
// A polished bust silhouette (head + shoulders) topped by a thin halo arc
// that crowns the head when selected. The halo expands outward as `spread`
// rises, like an aurora cresting over the brow.

/// Bust silhouette — single closed shape, no seams between head and shoulders.
struct YouBustShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2

        let headR = w * 0.20
        let headCY = h * 0.36
        let bottomY = h * 0.92
        let leftX = cx - w * 0.40
        let rightX = cx + w * 0.40
        let shoulderTopY = h * 0.72
        let neckHalfW = w * 0.13
        let neckTopY = headCY + headR * 0.92
        let headBottomY = headCY + headR

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: leftX, y: shoulderTopY))
        path.addCurve(
            to: CGPoint(x: cx - neckHalfW, y: neckTopY),
            control1: CGPoint(x: cx - w * 0.30, y: shoulderTopY - h * 0.02),
            control2: CGPoint(x: cx - w * 0.18, y: neckTopY + h * 0.02)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - headR * 0.85, y: headBottomY - headR * 0.30),
            control: CGPoint(x: cx - neckHalfW - w * 0.02, y: neckTopY - h * 0.02)
        )
        path.addArc(
            center: CGPoint(x: cx, y: headCY),
            radius: headR,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + neckHalfW, y: neckTopY),
            control: CGPoint(x: cx + neckHalfW + w * 0.02, y: neckTopY - h * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: rightX, y: shoulderTopY),
            control1: CGPoint(x: cx + w * 0.18, y: neckTopY + h * 0.02),
            control2: CGPoint(x: cx + w * 0.30, y: shoulderTopY - h * 0.02)
        )
        path.addLine(to: CGPoint(x: rightX, y: bottomY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY))
        path.closeSubpath()
        return path
    }
}

/// Halo arc above the head. `spread` 0…1 grows the arc outward from a tight
/// crown to a generous aurora.
struct YouHaloShape: Shape {
    var spread: CGFloat

    var animatableData: CGFloat {
        get { spread }
        set { spread = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2
        let headCY = h * 0.36
        let baseR = w * 0.30
        let r = baseR * (0.78 + spread * 0.40)

        var path = Path()
        // ~140° crown arc, opening downward toward the head
        path.addArc(
            center: CGPoint(x: cx, y: headCY),
            radius: r,
            startAngle: .degrees(200),
            endAngle: .degrees(340),
            clockwise: false
        )
        return path
    }
}

/// Combined silhouette for halo/glow. Just the bust (the halo is so thin
/// it doesn't need to contribute to the soft halo blur).
struct YouGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        YouBustShape().path(in: rect)
    }
}
