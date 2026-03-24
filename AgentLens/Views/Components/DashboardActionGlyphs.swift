import SwiftUI

// MARK: - Dashboard action toolbar glyphs
//
// Hand-authored vector art on a 24×24 grid (scaled to the requested size).
// Scan = read agent logs from disk; recount = clear derived totals and tally again.

enum DashboardActionGlyphKind {
    /// Pull in / refresh from log files on disk.
    case importFromLogs
    /// Rebuild usage from stored sessions (full recount).
    case sweepRecount
}

struct DashboardActionGlyph: View {
    var kind: DashboardActionGlyphKind
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            switch kind {
            case .importFromLogs:
                ImportFromLogsGlyph()
            case .sweepRecount:
                SweepRecountGlyph()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Import from logs (magnifier + log lines + tiny “eureka” sparkle)

private struct ImportFromLogsGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let w = s / 24
            ZStack {
                LogLinesUnderLens()
                    .stroke(style: StrokeStyle(lineWidth: max(1, 1.35 * w), lineCap: .round, lineJoin: .round))
                MagnifierWithHandle()
                    .stroke(style: StrokeStyle(lineWidth: max(1, 1.45 * w), lineCap: .round, lineJoin: .round))
                EurekaSparkle()
                    .stroke(style: StrokeStyle(lineWidth: max(0.85, 1.05 * w), lineCap: .round, lineJoin: .round))
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

private struct LogLinesUnderLens: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        p.move(to: t.p(2.8, 7.2))
        p.addLine(to: t.p(11.2, 7.2))
        p.move(to: t.p(2.8, 10))
        p.addLine(to: t.p(13.4, 10))
        p.move(to: t.p(2.8, 12.6))
        p.addLine(to: t.p(10.5, 12.6))
        return p
    }
}

private struct MagnifierWithHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        let c = t.p(15.4, 8.9)
        let r = 5.1 / 24 * min(rect.width, rect.height)
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        p.move(to: t.p(19.05, 12.15))
        p.addLine(to: t.p(22.7, 16.35))
        return p
    }
}

private struct EurekaSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        let o = t.p(4.1, 5.4)
        let a: CGFloat = 1.15 / 24 * min(rect.width, rect.height)
        p.move(to: CGPoint(x: o.x, y: o.y - a))
        p.addLine(to: CGPoint(x: o.x, y: o.y + a))
        p.move(to: CGPoint(x: o.x - a, y: o.y))
        p.addLine(to: CGPoint(x: o.x + a, y: o.y))
        return p
    }
}

// MARK: - Recount (broom sweeping little tally sticks)

private struct SweepRecountGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let w = s / 24
            ZStack {
                TallySticks()
                    .stroke(style: StrokeStyle(lineWidth: max(1, 1.25 * w), lineCap: .round, lineJoin: .round))
                BroomHead()
                    .stroke(style: StrokeStyle(lineWidth: max(1, 1.35 * w), lineCap: .round, lineJoin: .round))
                BroomHandle()
                    .stroke(style: StrokeStyle(lineWidth: max(1, 1.2 * w), lineCap: .round, lineJoin: .round))
                BroomBristleTexture()
                    .stroke(style: StrokeStyle(lineWidth: max(0.8, 0.95 * w), lineCap: .round, lineJoin: .round))
                WhimsySpeedLine()
                    .stroke(style: StrokeStyle(lineWidth: max(0.75, 0.9 * w), lineCap: .round, lineJoin: .round))
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

private struct TallySticks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        for x: CGFloat in [3.4, 5.1, 6.8, 8.5] {
            p.move(to: t.p(x, 16.4))
            p.addLine(to: t.p(x, 19.6))
        }
        return p
    }
}

private struct BroomHead: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        p.move(to: t.p(11.8, 7.8))
        p.addQuadCurve(to: t.p(17.6, 8.6), control: t.p(14.8, 6.9))
        p.addLine(to: t.p(16.9, 11.8))
        p.addQuadCurve(to: t.p(12.2, 10.8), control: t.p(14.5, 12.1))
        p.closeSubpath()
        return p
    }
}

private struct BroomHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        p.move(to: t.p(14.8, 11.2))
        p.addQuadCurve(to: t.p(21.2, 18.6), control: t.p(18.5, 14.2))
        return p
    }
}

private struct BroomBristleTexture: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        p.move(to: t.p(13.2, 9.4))
        p.addLine(to: t.p(13.8, 10.9))
        p.move(to: t.p(15.1, 9.1))
        p.addLine(to: t.p(15.6, 10.8))
        p.move(to: t.p(16.8, 9.5))
        p.addLine(to: t.p(17.1, 11))
        return p
    }
}

private struct WhimsySpeedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = Transform(rect: rect)
        p.move(to: t.p(10.4, 13.6))
        p.addQuadCurve(to: t.p(7.6, 12.2), control: t.p(9.1, 12.7))
        return p
    }
}

// MARK: - 24×24 grid → rect

private struct Transform {
    let rect: CGRect
    private var s: CGFloat { min(rect.width, rect.height) }
    private var ox: CGFloat { rect.midX - s / 2 }
    private var oy: CGFloat { rect.midY - s / 2 }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: ox + x / 24 * s, y: oy + y / 24 * s)
    }
}
