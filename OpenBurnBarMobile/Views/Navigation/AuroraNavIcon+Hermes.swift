import SwiftUI

// MARK: - 4. Hermes (Friendly Robot Head)
//
// A characterful little robot: rounded helmet head, padded headphones with
// circular earcups, a heart-tipped antenna, two big expressive pupils, a
// gentle smile arc, and rosy cheek dots that brighten when selected. When
// the tab activates, the eyes wake up coral, the cheeks blush, the antenna
// heart pulses, and a tiny "happy curve" appears under each pupil so the
// robot reads as smiling-with-its-eyes.
//
// Geometry frame of reference:
//   • Head:        rounded squircle, slightly squat
//   • Headphones:  band over the top + earcups on each side
//   • Eyes:        two large rounded-rect pupils centered horizontally
//   • Smile arc:   curved arc that widens when selected
//   • Cheeks:      two faint circles flanking the smile
//   • Antenna:     stalk + heart tip rising from the helmet's crown

enum HermesRobotMetrics {
    static func head(in rect: CGRect) -> CGRect {
        let w = rect.width
        let h = rect.height
        let headW = w * 0.66
        let headH = h * 0.56
        let headX = (w - headW) / 2
        let headY = h * 0.30
        return CGRect(x: headX, y: headY, width: headW, height: headH)
    }
}

/// Helmet body — soft rounded squircle.
struct HermesHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        return Path(roundedRect: head, cornerRadius: head.width * 0.36)
    }
}

/// Two earcup circles flanking the helmet (the headphones' speakers).
struct HermesEarcupsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.midY
        let r = head.width * 0.13
        var path = Path()
        path.addEllipse(in: CGRect(
            x: head.minX - r * 0.6, y: cy - r,
            width: r * 2, height: r * 2
        ))
        path.addEllipse(in: CGRect(
            x: head.maxX - r * 1.4, y: cy - r,
            width: r * 2, height: r * 2
        ))
        return path
    }
}

/// Antenna stalk that rises from the crown of the helmet.
struct HermesAntennaShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cx = head.midX
        let baseY = head.minY + 1
        let tipY = max(rect.minY + rect.height * 0.05, baseY - rect.height * 0.20)
        var path = Path()
        path.move(to: CGPoint(x: cx, y: baseY))
        path.addLine(to: CGPoint(x: cx, y: tipY))
        return path
    }
}

/// Heart-shaped tip on the antenna (replaces a plain knob — friendlier).
struct HermesAntennaHeartShape: Shape {
    var pulse: CGFloat
    var animatableData: CGFloat {
        get { pulse }
        set { pulse = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cx = head.midX
        let tipY = max(rect.minY + rect.height * 0.05, head.minY - rect.height * 0.20)
        let scale = 1.0 + pulse * 0.18
        let w = rect.width * 0.13 * scale
        let h = w * 0.92
        let centerY = tipY - h * 0.45

        // Classic heart constructed from two arcs + a bottom V.
        var path = Path()
        let leftCenter = CGPoint(x: cx - w * 0.25, y: centerY - h * 0.05)
        let rightCenter = CGPoint(x: cx + w * 0.25, y: centerY - h * 0.05)
        let lobeR = w * 0.30

        path.move(to: CGPoint(x: cx, y: centerY))
        path.addArc(
            center: leftCenter, radius: lobeR,
            startAngle: .degrees(0), endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: cx, y: centerY + h * 0.55))
        path.addLine(to: CGPoint(x: cx + lobeR * 2, y: centerY))
        path.addArc(
            center: rightCenter, radius: lobeR,
            startAngle: .degrees(0), endAngle: .degrees(180),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

/// Two large pupils (rounded rects, not dots) so the robot reads as having
/// eyes, not just LEDs. `glow` grows them slightly on activation.
struct HermesEyesShape: Shape {
    var glow: CGFloat
    var animatableData: CGFloat {
        get { glow }
        set { glow = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.minY + head.height * 0.40
        let xOffset = head.width * 0.20
        let baseW = head.width * 0.18
        let baseH = head.height * 0.20
        let scale = 1.0 + glow * 0.10
        let w = baseW * scale
        let h = baseH * scale
        let r = w * 0.40

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: head.midX - xOffset - w / 2, y: cy - h / 2, width: w, height: h),
            cornerSize: CGSize(width: r, height: r)
        )
        path.addRoundedRect(
            in: CGRect(x: head.midX + xOffset - w / 2, y: cy - h / 2, width: w, height: h),
            cornerSize: CGSize(width: r, height: r)
        )
        return path
    }
}

/// "Smile lines" — small upturned arcs under each pupil that appear when
/// the eyes wake up so the robot reads as smiling with its eyes.
struct HermesEyeSmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let baseY = head.minY + head.height * 0.52
        let xOffset = head.width * 0.20
        let arcW = head.width * 0.18
        let dip = head.height * 0.04

        var path = Path()
        // Left
        path.move(to: CGPoint(x: head.midX - xOffset - arcW / 2, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: head.midX - xOffset + arcW / 2, y: baseY),
            control: CGPoint(x: head.midX - xOffset, y: baseY + dip)
        )
        // Right
        path.move(to: CGPoint(x: head.midX + xOffset - arcW / 2, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: head.midX + xOffset + arcW / 2, y: baseY),
            control: CGPoint(x: head.midX + xOffset, y: baseY + dip)
        )
        return path
    }
}

/// Gentle smile arc — wider when selected (`open` = 1) so the robot grins.
struct HermesSmileShape: Shape {
    var open: CGFloat
    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.minY + head.height * 0.74
        let baseW = head.width * 0.34
        let w = baseW * (0.85 + open * 0.30)
        let dip = head.height * (0.06 + open * 0.05)

        var path = Path()
        path.move(to: CGPoint(x: head.midX - w / 2, y: cy))
        path.addQuadCurve(
            to: CGPoint(x: head.midX + w / 2, y: cy),
            control: CGPoint(x: head.midX, y: cy + dip)
        )
        return path
    }
}

/// Two small cheek circles flanking the smile — blush dots.
struct HermesCheeksShape: Shape {
    func path(in rect: CGRect) -> Path {
        let head = HermesRobotMetrics.head(in: rect)
        let cy = head.minY + head.height * 0.74
        let xOffset = head.width * 0.30
        let r = head.width * 0.05
        var path = Path()
        path.addEllipse(in: CGRect(
            x: head.midX - xOffset - r, y: cy - r,
            width: r * 2, height: r * 2
        ))
        path.addEllipse(in: CGRect(
            x: head.midX + xOffset - r, y: cy - r,
            width: r * 2, height: r * 2
        ))
        return path
    }
}

/// Combined silhouette (head + earcups + heart) for halo glow when on.
struct HermesGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = HermesHeadShape().path(in: rect)
        path.addPath(HermesEarcupsShape().path(in: rect))
        path.addPath(HermesAntennaHeartShape(pulse: 0).path(in: rect))
        return path
    }
}
