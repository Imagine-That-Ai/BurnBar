import SwiftUI

// MARK: - 1. Vitalis (Pulse)
// A vitals waveform — one tall peak, then a softer dip. The selected state
// fills the area UNDER the curve down to the baseline with a multi-stop
// ember→amber→clear gradient, evoking a sparkline area chart.

/// The line component of Vitalis — peak then valley.
struct VitalisLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let baseline = h * 0.74
        let amplitude = h * 0.50

        var path = Path()
        let p0 = CGPoint(x: w * 0.06, y: baseline)
        let p1 = CGPoint(x: w * 0.26, y: baseline - amplitude * 0.18)
        let peak = CGPoint(x: w * 0.46, y: baseline - amplitude)
        let dip = CGPoint(x: w * 0.66, y: baseline + amplitude * 0.05)
        let p3 = CGPoint(x: w * 0.84, y: baseline - amplitude * 0.30)
        let pEnd = CGPoint(x: w * 0.96, y: baseline - amplitude * 0.10)

        path.move(to: p0)
        path.addCurve(to: p1,
                      control1: CGPoint(x: w * 0.14, y: baseline),
                      control2: CGPoint(x: w * 0.20, y: baseline - amplitude * 0.04))
        path.addCurve(to: peak,
                      control1: CGPoint(x: w * 0.34, y: baseline - amplitude * 0.55),
                      control2: CGPoint(x: w * 0.40, y: baseline - amplitude))
        path.addCurve(to: dip,
                      control1: CGPoint(x: w * 0.52, y: baseline - amplitude),
                      control2: CGPoint(x: w * 0.58, y: baseline + amplitude * 0.05))
        path.addCurve(to: p3,
                      control1: CGPoint(x: w * 0.74, y: baseline + amplitude * 0.05),
                      control2: CGPoint(x: w * 0.78, y: baseline - amplitude * 0.20))
        path.addCurve(to: pEnd,
                      control1: CGPoint(x: w * 0.90, y: baseline - amplitude * 0.04),
                      control2: CGPoint(x: w * 0.94, y: baseline - amplitude * 0.06))
        return path
    }
}

/// Closed area-under-curve down to the baseline.
struct VitalisAreaShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let baseline = rect.height * 0.74
        var path = VitalisLineShape().path(in: rect)
        path.addLine(to: CGPoint(x: w * 0.96, y: baseline))
        path.addLine(to: CGPoint(x: w * 0.06, y: baseline))
        path.closeSubpath()
        return path
    }
}
