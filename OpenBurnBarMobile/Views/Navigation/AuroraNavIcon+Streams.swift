import SwiftUI

// MARK: - 3. Streams (Vintage Antenna TV)
//
// A boxy retro TV cabinet with two rabbit-ear antennae at the top. When
// selected the screen "powers on": a CRT scanline expands from the center
// outward (vertical → horizontal sweep), and three signal bars resolve
// inside the screen. Tapping an unselected tab plays the power-on; leaving
// the tab fades the screen back to standby.
//
// Geometry frame of reference:
//   • Cabinet:  rounded rect, occupies the lower 64% of the canvas
//   • Screen:   inner rounded rect, ~76% of the cabinet
//   • Antennae: two short diagonal lines + tiny knobs at the top
//   • Foot:     two stubby legs hanging below the cabinet

/// Outer cabinet body of the TV (rounded rectangle).
struct StreamsTVCabinetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cabinetRect = StreamsTVMetrics.cabinet(in: rect)
        return Path(roundedRect: cabinetRect, cornerRadius: rect.width * 0.10)
    }
}

/// Inner screen region — a slightly inset rounded rectangle that takes the
/// brand gradient when powered on.
struct StreamsTVScreenShape: Shape {
    func path(in rect: CGRect) -> Path {
        let screenRect = StreamsTVMetrics.screen(in: rect)
        return Path(roundedRect: screenRect, cornerRadius: rect.width * 0.06)
    }
}

/// Two diagonal rabbit-ear antennae rising from the top of the cabinet.
/// `lift` 0…1 nudges the tips slightly outward and upward when on.
struct StreamsTVAntennaShape: Shape {
    var lift: CGFloat

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cabinetTop = StreamsTVMetrics.cabinet(in: rect).minY
        let cx = w / 2
        let baseSpread = w * 0.08
        let baseY = cabinetTop + 1
        // Antenna lengths
        let tipDX = w * (0.30 + lift * 0.04)
        let tipDY = w * (0.32 + lift * 0.05)

        var path = Path()
        // Left antenna
        path.move(to: CGPoint(x: cx - baseSpread, y: baseY))
        path.addLine(to: CGPoint(x: cx - baseSpread - tipDX, y: baseY - tipDY))
        // Right antenna
        path.move(to: CGPoint(x: cx + baseSpread, y: baseY))
        path.addLine(to: CGPoint(x: cx + baseSpread + tipDX, y: baseY - tipDY))
        return path
    }
}

/// Two tiny tip-knobs that cap the antennae. Drawn separately because we
/// fill them, not stroke them.
struct StreamsTVAntennaTipsShape: Shape {
    var lift: CGFloat

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cabinetTop = StreamsTVMetrics.cabinet(in: rect).minY
        let cx = w / 2
        let baseSpread = w * 0.08
        let baseY = cabinetTop + 1
        let tipDX = w * (0.30 + lift * 0.04)
        let tipDY = w * (0.32 + lift * 0.05)
        let r = w * 0.035

        var path = Path()
        path.addEllipse(in: CGRect(
            x: cx - baseSpread - tipDX - r,
            y: baseY - tipDY - r,
            width: r * 2, height: r * 2
        ))
        path.addEllipse(in: CGRect(
            x: cx + baseSpread + tipDX - r,
            y: baseY - tipDY - r,
            width: r * 2, height: r * 2
        ))
        return path
    }
}

/// Two stubby legs that hang below the cabinet — completes the silhouette.
struct StreamsTVFeetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cabinet = StreamsTVMetrics.cabinet(in: rect)
        let footY = cabinet.maxY
        let footH = w * 0.06
        let footW = w * 0.08
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                x: cabinet.midX - cabinet.width * 0.30 - footW / 2,
                y: footY,
                width: footW, height: footH
            ),
            cornerSize: CGSize(width: w * 0.018, height: w * 0.018)
        )
        path.addRoundedRect(
            in: CGRect(
                x: cabinet.midX + cabinet.width * 0.30 - footW / 2,
                y: footY,
                width: footW, height: footH
            ),
            cornerSize: CGSize(width: w * 0.018, height: w * 0.018)
        )
        return path
    }
}

/// CRT power-on sweep — a thin bright bar that expands from the screen's
/// center, first as a vertical hairline, then sweeping out horizontally.
/// `progress` 0…1: 0 = invisible, 0.4 = vertical line, 1 = fully open.
struct StreamsTVScanlineShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        // First half: vertical hairline grows in height. Second half: hairline
        // becomes a horizontal sweep that opens to fill the screen.
        let p = max(0, min(1, progress))
        let firstHalf = min(1, p / 0.45)            // 0…1 over progress 0…0.45
        let secondHalf = max(0, (p - 0.45) / 0.55)  // 0…1 over progress 0.45…1

        // The sweep's height grows from 0 → screen.height during firstHalf
        let openH = screen.height * firstHalf
        // The sweep's width grows from a hairline → screen.width during secondHalf
        let minSweepW = screen.height * 0.06
        let openW = minSweepW + (screen.width - minSweepW) * secondHalf

        let sweepRect = CGRect(
            x: screen.midX - openW / 2,
            y: screen.midY - openH / 2,
            width: openW, height: openH
        )
        return Path(roundedRect: sweepRect, cornerRadius: rect.width * 0.018)
    }
}

/// Combined silhouette of TV (cabinet + antennae + feet) — used for halo glow.
struct StreamsGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = StreamsTVCabinetShape().path(in: rect)
        path.addPath(StreamsTVAntennaTipsShape(lift: 0).path(in: rect))
        path.addPath(StreamsTVFeetShape().path(in: rect))
        return path
    }
}

/// Shared cabinet/screen metrics — defined once so all sub-shapes line up
/// pixel-perfectly even when the size changes (28pt sidebar vs 22pt tray).
enum StreamsTVMetrics {
    static func cabinet(in rect: CGRect) -> CGRect {
        let w = rect.width
        let h = rect.height
        let cabinetW = w * 0.84
        let cabinetH = h * 0.56
        let cabinetX = (w - cabinetW) / 2
        let cabinetY = h * 0.30
        return CGRect(x: cabinetX, y: cabinetY, width: cabinetW, height: cabinetH)
    }

    static func screen(in rect: CGRect) -> CGRect {
        let cab = cabinet(in: rect)
        return cab.insetBy(dx: cab.width * 0.10, dy: cab.height * 0.16)
    }
}

/// Color test pattern — a single rectangle the size of the inner screen.
/// We fill it with a multi-stop linear gradient that visually reads as
/// 7 vertical color bars (SMPTE-style).
struct StreamsTVColorBarsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        return Path(screen)
    }
}

/// Glossy specular curve over the screen — sells the convex CRT glass.
struct StreamsTVScreenGlossShape: Shape {
    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        var path = Path()
        // Curved highlight covering the upper-left quadrant of the screen.
        let topLeft = CGPoint(x: screen.minX + screen.width * 0.06, y: screen.minY + screen.height * 0.10)
        let topRight = CGPoint(x: screen.minX + screen.width * 0.92, y: screen.minY + screen.height * 0.16)
        let dipMid = CGPoint(x: screen.midX, y: screen.minY + screen.height * 0.42)
        path.move(to: topLeft)
        path.addQuadCurve(to: topRight,
                          control: CGPoint(x: screen.midX, y: screen.minY + screen.height * 0.02))
        path.addQuadCurve(to: topLeft,
                          control: dipMid)
        path.closeSubpath()
        return path
    }
}

/// The leading edge of the CRT power-on sweep — a thin horizontal line that
/// sits at the top + bottom of the opening rectangle while it expands. We
/// only animate it during the second-half horizontal phase (when the open
/// rect actually has a meaningful width); the vertical hairline phase is
/// covered by the bar growth itself.
struct StreamsTVScanlineEdgeShape: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let screen = StreamsTVMetrics.screen(in: rect)
        let p = max(0, min(1, progress))
        let secondHalf = max(0, (p - 0.45) / 0.55)
        let openH = screen.height * min(1, p / 0.45)
        let minSweepW = screen.height * 0.06
        let openW = minSweepW + (screen.width - minSweepW) * secondHalf

        let topY = screen.midY - openH / 2
        let bottomY = screen.midY + openH / 2
        let leftX = screen.midX - openW / 2
        let rightX = screen.midX + openW / 2

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: rightX, y: topY))
        path.move(to: CGPoint(x: leftX, y: bottomY))
        path.addLine(to: CGPoint(x: rightX, y: bottomY))
        return path
    }
}
