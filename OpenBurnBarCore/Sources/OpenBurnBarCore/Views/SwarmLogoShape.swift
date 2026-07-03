#if canImport(SwiftUI)
import Foundation
import CoreGraphics

// remediation(core-swarm-decomp): relocated verbatim from SwarmCanvasView.swift to
// shrink that 3,926-line god-file. Behavior-preserving move only; SwiftPM directory
// auto-discovery picks this sibling up automatically.

enum SwarmLogoShape {
    struct Point: Equatable {
        let point: CGPoint
        let role: String
        let progress: Double
    }

    static func generatePoints() -> [Point] {
        var raw: [RawPoint] = []

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 171.6, y: 4.7),
                CGPoint(x: 149, y: 24),
                CGPoint(x: 126, y: 54),
                CGPoint(x: 112.8, y: 98.3),
                CGPoint(x: 105, y: 84),
                CGPoint(x: 94.7, y: 79.6),
                CGPoint(x: 96, y: 97),
                CGPoint(x: 80.6, y: 125.1),
                CGPoint(x: 78, y: 112),
                CGPoint(x: 75.1, y: 105.8),
                CGPoint(x: 54, y: 130),
                CGPoint(x: 35.7, y: 183),
                CGPoint(x: 39, y: 202),
                CGPoint(x: 52.3, y: 224.2),
                CGPoint(x: 52.3, y: 213.6),
                CGPoint(x: 56.9, y: 209.6),
                CGPoint(x: 82.2, y: 209.6),
                CGPoint(x: 71, y: 192),
                CGPoint(x: 80, y: 166),
                CGPoint(x: 103.3, y: 144.9),
                CGPoint(x: 101, y: 155),
                CGPoint(x: 112.5, y: 168.8),
                CGPoint(x: 145, y: 158),
                CGPoint(x: 167.3, y: 133.2),
                CGPoint(x: 173, y: 111),
                CGPoint(x: 159, y: 72.1),
                CGPoint(x: 162, y: 42),
                CGPoint(x: 171.6, y: 4.7)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-outer"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 219.4, y: 165.8),
                CGPoint(x: 218, y: 143),
                CGPoint(x: 210, y: 121),
                CGPoint(x: 203.2, y: 106.3),
                CGPoint(x: 196.5, y: 108.5),
                CGPoint(x: 193.5, y: 127),
                CGPoint(x: 182.2, y: 139.2),
                CGPoint(x: 181.3, y: 143.3),
                CGPoint(x: 187.5, y: 144.7),
                CGPoint(x: 192.2, y: 149.5),
                CGPoint(x: 192.2, y: 225.9),
                CGPoint(x: 207, y: 211),
                CGPoint(x: 219.4, y: 184),
                CGPoint(x: 219.4, y: 165.8)
            ],
            samplesPerSegment: 3,
            role: "logo-flame-outer"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 166, y: 6),
                CGPoint(x: 147, y: 24),
                CGPoint(x: 132, y: 53),
                CGPoint(x: 124, y: 80),
                CGPoint(x: 121, y: 105),
                CGPoint(x: 110, y: 125),
                CGPoint(x: 96, y: 137),
                CGPoint(x: 82, y: 144),
                CGPoint(x: 74, y: 142),
                CGPoint(x: 73, y: 130),
                CGPoint(x: 80, y: 113),
                CGPoint(x: 64, y: 132),
                CGPoint(x: 51, y: 157),
                CGPoint(x: 48, y: 184),
                CGPoint(x: 50, y: 193)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-inner"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 168, y: 6),
                CGPoint(x: 155, y: 30),
                CGPoint(x: 148, y: 56),
                CGPoint(x: 150, y: 80),
                CGPoint(x: 160, y: 111),
                CGPoint(x: 150, y: 133),
                CGPoint(x: 131, y: 153),
                CGPoint(x: 111, y: 164),
                CGPoint(x: 104, y: 147)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-inner"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 74, y: 113),
                CGPoint(x: 62, y: 128),
                CGPoint(x: 56, y: 145),
                CGPoint(x: 62, y: 151),
                CGPoint(x: 71, y: 151),
                CGPoint(x: 50, y: 178)
            ],
            samplesPerSegment: 3,
            role: "logo-flame-spark"
        )

        appendBar(into: &raw, minX: 58.6, maxX: 84.7, topY: 216.6, bottomY: 248.0, role: "logo-bar-1")
        appendBar(into: &raw, minX: 91.3, maxX: 118.5, topY: 195.2, bottomY: 252.0, role: "logo-bar-2")
        appendBar(into: &raw, minX: 124.9, maxX: 151.5, topY: 176.9, bottomY: 252.0, role: "logo-bar-3")
        appendBar(into: &raw, minX: 157.8, maxX: 185.7, topY: 150.6, bottomY: 246.4, role: "logo-bar-4")
        appendBar(into: &raw, minX: 192.2, maxX: 219.4, topY: 108.0, bottomY: 226.0, role: "logo-bar-5")

        let denominator = max(1, raw.count - 1)
        return raw.enumerated().map { index, point in
            Point(
                point: normalize(point.source),
                role: point.role,
                progress: Double(index) / Double(denominator)
            )
        }
    }

    private struct RawPoint {
        let source: CGPoint
        let role: String
    }

    private static let sourceCenter = CGPoint(x: 128, y: 128)
    private static let sourceScale: CGFloat = 150
    private static let barStep: CGFloat = 13

    private static func normalize(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - sourceCenter.x) / sourceScale,
            y: (point.y - sourceCenter.y) / sourceScale
        )
    }

    private static func appendBar(
        into raw: inout [RawPoint],
        minX: CGFloat,
        maxX: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        role: String
    ) {
        for y in strideValues(from: topY, through: bottomY, by: barStep) {
            for x in strideValues(from: minX, through: maxX, by: barStep) {
                raw.append(RawPoint(source: CGPoint(x: x, y: y), role: role))
            }
        }
    }

    private static func appendCatmullRom(
        into raw: inout [RawPoint],
        controls: [CGPoint],
        samplesPerSegment: Int,
        role: String
    ) {
        guard controls.count >= 2 else { return }
        let samples = max(1, samplesPerSegment)
        for index in 0..<(controls.count - 1) {
            let p0 = controls[max(0, index - 1)]
            let p1 = controls[index]
            let p2 = controls[index + 1]
            let p3 = controls[min(controls.count - 1, index + 2)]
            for sample in 0..<samples {
                let t = CGFloat(sample) / CGFloat(samples)
                raw.append(RawPoint(source: catmullRom(p0, p1, p2, p3, t: t), role: role))
            }
        }
        raw.append(RawPoint(source: controls[controls.count - 1], role: role))
    }

    private static func catmullRom(
        _ p0: CGPoint,
        _ p1: CGPoint,
        _ p2: CGPoint,
        _ p3: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let x = 0.5 * (
            (2 * p1.x)
            + (-p0.x + p2.x) * t
            + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
            + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y)
            + (-p0.y + p2.y) * t
            + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
            + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )
        return CGPoint(x: x, y: y)
    }

    private static func strideValues(from start: CGFloat, through end: CGFloat, by step: CGFloat) -> [CGFloat] {
        var values: [CGFloat] = []
        var current = start
        while current <= end {
            values.append(current)
            current += step
        }
        if values.last != end {
            values.append(end)
        }
        return values
    }
}

#endif
