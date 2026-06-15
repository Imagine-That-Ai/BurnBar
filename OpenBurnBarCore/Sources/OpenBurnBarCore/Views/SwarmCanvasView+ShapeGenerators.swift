import SwiftUI
import Foundation
import CoreGraphics
import CoreText
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Procedural shape + provider-logo point generators and spline helpers.
// Extracted from SwarmCanvasView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension SwarmSimulation {

    static func generateSkilletPoints() -> [ShapePoint] {
        sampleEmojiPoints(emoji: "🍳", fontSize: 210)
    }

    static func generateApplePoints() -> [ShapePoint] {
        sampleEmojiPoints(emoji: "🍎", fontSize: 210)
    }

    static func generateChefHatPoints() -> [ShapePoint] {
        sampleEmojiPoints(emoji: "👨‍🍳", fontSize: 210)
    }

    static func generateChiliPoints() -> [ShapePoint] {
        sampleEmojiPoints(emoji: "🌶️", fontSize: 210)
    }

    static func generateRingPoints(numRings: Int = 3) -> [ShapePoint] {
        var pts: [ShapePoint] = []
        for ring in 0..<numRings {
            let radius = 0.2 + Double(ring) * 0.25
            let count = 80 + ring * 50
            for i in 0..<count {
                let angle = Double(i) / Double(count) * .pi * 2
                pts.append(ShapePoint(
                    point: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius),
                    role: nil,
                    progress: Double.random(in: 0...1)
                ))
            }
        }
        return pts
    }

    static func generateRouterFlowPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        // Central gateway node
        let gatewayCount = 100
        for i in 0..<gatewayCount {
            let angle = Double(i) / Double(gatewayCount) * .pi * 2
            let r = 0.08
            pts.append(ShapePoint(
                point: CGPoint(x: -0.45 + cos(angle) * r, y: sin(angle) * r),
                role: "gateway",
                progress: Double(i) / Double(gatewayCount)
            ))
        }
        // Target nodes
        struct Target { let x: Double; let y: Double; let role: String }
        let targets = [
            Target(x: 0.45, y: -0.28, role: "target-1"),
            Target(x: 0.45, y: 0.00, role: "target-2"),
            Target(x: 0.45, y: 0.28, role: "target-3")
        ]
        for tgt in targets {
            let count = 50
            for i in 0..<count {
                let angle = Double(i) / Double(count) * .pi * 2
                let r = 0.05
                pts.append(ShapePoint(
                    point: CGPoint(x: tgt.x + cos(angle) * r, y: tgt.y + sin(angle) * r),
                    role: tgt.role,
                    progress: Double(i) / Double(count)
                ))
            }
        }
        // Bezier connector paths — particles ride these as live request packets.
        for (idx, tgt) in targets.enumerated() {
            let count = 60
            let pathRole = "path-\(idx + 1)"
            for i in 0..<count {
                let t = Double(i) / Double(count)
                let px = -0.45 + (tgt.x - -0.45) * t
                let py = (tgt.y) * (3 * t * t - 2 * t * t * t)
                pts.append(ShapePoint(
                    point: CGPoint(x: px, y: py),
                    role: pathRole,
                    progress: t
                ))
            }
        }
        return pts
    }

    static func interpolateCatmullRom(
        _ p0: CGPoint,
        _ p1: CGPoint,
        _ p2: CGPoint,
        _ p3: CGPoint,
        t: Double
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2.0 * p1.x) +
            (-p0.x + p2.x) * t +
            (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 +
            (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2.0 * p1.y) +
            (-p0.y + p2.y) * t +
            (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 +
            (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3
        )
        return CGPoint(x: x, y: y)
    }

    static func generateSplinePoints(
        controlPoints: [CGPoint],
        stepsPerSegment: Int,
        role: String?
    ) -> [ShapePoint] {
        guard controlPoints.count >= 3 else { return [] }
        var pts: [ShapePoint] = []
        let n = controlPoints.count
        for i in 0..<n {
            let p0 = controlPoints[(i - 1 + n) % n]
            let p1 = controlPoints[i]
            let p2 = controlPoints[(i + 1) % n]
            let p3 = controlPoints[(i + 2) % n]

            for j in 0..<stepsPerSegment {
                let t = Double(j) / Double(stepsPerSegment)
                let pt = interpolateCatmullRom(p0, p1, p2, p3, t: t)
                let progress = Double(i * stepsPerSegment + j) / Double(n * stepsPerSegment)
                pts.append(ShapePoint(point: pt, role: role, progress: progress))
            }
        }
        return pts
    }

    static func generateOpenAILogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []
        let majorAxis = 0.22
        let minorAxis = 0.07
        let d = 0.12
        let alpha = 0.2
        let steps = 70
        for i in 0..<6 {
            let theta = Double(i) * (.pi / 3.0)
            for j in 0..<steps {
                let t = Double(j) / Double(steps) * (.pi * 2.0)
                let localX = d + majorAxis * cos(t) * cos(alpha) - minorAxis * sin(t) * sin(alpha)
                let localY = majorAxis * cos(t) * sin(alpha) + minorAxis * sin(t) * cos(alpha)

                let x = localX * cos(theta) - localY * sin(theta)
                let y = localX * sin(theta) + localY * cos(theta)

                pts.append(ShapePoint(
                    point: CGPoint(x: x, y: y),
                    role: "logo-flame-inner",
                    progress: Double(j) / Double(steps)
                ))
            }
        }
        return pts
    }

    static func generateAnthropicLogoPoints() -> [ShapePoint] {
        let outer = [
            CGPoint(x: -0.22, y: -0.30),
            CGPoint(x: -0.07, y: 0.32),
            CGPoint(x: 0.07, y: 0.32),
            CGPoint(x: 0.22, y: -0.30),
            CGPoint(x: 0.12, y: -0.30),
            CGPoint(x: 0.0, y: 0.02),
            CGPoint(x: -0.12, y: -0.30)
        ]
        let inner = [
            CGPoint(x: 0.0, y: 0.20),
            CGPoint(x: 0.05, y: 0.08),
            CGPoint(x: -0.05, y: 0.08)
        ]

        let outerPts = generateSplinePoints(controlPoints: outer, stepsPerSegment: 35, role: "logo-flame-outer")
        let innerPts = generateSplinePoints(controlPoints: inner, stepsPerSegment: 35, role: "logo-flame-inner")
        return outerPts + innerPts
    }

    static func generateGeminiLogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []
        let outerR = 0.34
        let innerR = 0.18

        // Outer astroid
        let outerCount = 220
        for i in 0..<outerCount {
            let t = Double(i) / Double(outerCount) * (.pi * 2.0)
            let x = outerR * pow(cos(t), 3)
            let y = outerR * pow(sin(t), 3)
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-outer",
                progress: Double(i) / Double(outerCount)
            ))
        }

        // Inner astroid
        let innerCount = 150
        for i in 0..<innerCount {
            let t = Double(i) / Double(innerCount) * (.pi * 2.0)
            let x = innerR * pow(cos(t), 3)
            let y = innerR * pow(sin(t), 3)
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-inner",
                progress: Double(i) / Double(innerCount)
            ))
        }
        return pts
    }

    static func generateCursorLogoPoints() -> [ShapePoint] {
        let controlPoints = [
            CGPoint(x: 0.0, y: 0.32),
            CGPoint(x: 0.18, y: -0.18),
            CGPoint(x: 0.0, y: -0.05),
            CGPoint(x: -0.18, y: -0.18)
        ]
        return generateSplinePoints(controlPoints: controlPoints, stepsPerSegment: 90, role: "logo-flame-inner")
    }

    static func generateOpenCodeLogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        func appendLine(
            startX: Double,
            startY: Double,
            endX: Double,
            endY: Double,
            count: Int,
            role: String
        ) {
            for i in 0..<count {
                let t = Double(i) / Double(max(count - 1, 1))
                pts.append(ShapePoint(
                    point: CGPoint(
                        x: startX + (endX - startX) * t,
                        y: startY + (endY - startY) * t
                    ),
                    role: role,
                    progress: t
                ))
            }
        }

        appendLine(startX: -0.34, startY: 0.0, endX: -0.12, endY: -0.22, count: 90, role: "logo-flame-outer")
        appendLine(startX: -0.34, startY: 0.0, endX: -0.12, endY: 0.22, count: 90, role: "logo-flame-inner")
        appendLine(startX: 0.34, startY: 0.0, endX: 0.12, endY: -0.22, count: 90, role: "logo-flame-outer")
        appendLine(startX: 0.34, startY: 0.0, endX: 0.12, endY: 0.22, count: 90, role: "logo-flame-inner")
        appendLine(startX: -0.04, startY: 0.30, endX: 0.08, endY: -0.30, count: 120, role: "logo-flame-spark")
        return pts
    }

    static func generateXAILogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        // x.ai folded X diagonal 1: Top-Left to Bottom-Right
        let diagonalCount = 140
        for i in 0..<diagonalCount {
            let t = Double(i) / Double(diagonalCount)
            let x = -0.22 + t * 0.44
            let y = 0.25 - t * 0.50

            pts.append(ShapePoint(
                point: CGPoint(x: x - 0.015, y: y),
                role: "logo-flame-outer",
                progress: t
            ))
            pts.append(ShapePoint(
                point: CGPoint(x: x + 0.015, y: y),
                role: "logo-flame-inner",
                progress: t
            ))
        }

        // x.ai diagonal 2: Bottom-Left to Top-Right split segments
        let segmentCount = 60
        // Bottom-Left segment
        for i in 0..<segmentCount {
            let t = Double(i) / Double(segmentCount)
            let x = -0.22 + t * 0.16
            let y = -0.25 + t * 0.18
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-spark",
                progress: t * 0.5
            ))
        }
        // Top-Right segment
        for i in 0..<segmentCount {
            let t = Double(i) / Double(segmentCount)
            let x = 0.06 + t * 0.16
            let y = 0.07 + t * 0.18
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-spark",
                progress: 0.5 + t * 0.5
            ))
        }
        return pts
    }

    static func generateOllamaLogoPoints() -> [ShapePoint] {
        let coords: [CGPoint] = [
            CGPoint(x: -0.19965000000000002, y: -0.55), CGPoint(x: -0.19415000000000002, y: -0.54747), CGPoint(x: -0.18700000000000003, y: -0.54329), CGPoint(x: -0.18183000000000002, y: -0.53966),
            CGPoint(x: -0.17688, y: -0.5354800000000001), CGPoint(x: -0.16962000000000002, y: -0.5281100000000001), CGPoint(x: -0.16225, y: -0.51898), CGPoint(x: -0.15532, y: -0.50875), CGPoint(x: -0.14696, y: -0.49335000000000007),
            CGPoint(x: -0.14135, y: -0.4807), CGPoint(x: -0.13618, y: -0.4671700000000001), CGPoint(x: -0.13046000000000002, y: -0.44814000000000004), CGPoint(x: -0.12683, y: -0.43351000000000006),
            CGPoint(x: -0.12397000000000001, y: -0.41855000000000003), CGPoint(x: -0.12188, y: -0.40337000000000006), CGPoint(x: -0.12067000000000001, y: -0.39325), CGPoint(x: -0.12012000000000002, y: -0.39325),
            CGPoint(x: -0.11968000000000001, y: -0.39325), CGPoint(x: -0.11913, y: -0.39336), CGPoint(x: -0.11869, y: -0.39336), CGPoint(x: -0.10329, y: -0.39413000000000004), CGPoint(x: -0.07315, y: -0.39259000000000005),
            CGPoint(x: -0.05115, y: -0.38874000000000003), CGPoint(x: -0.0297, y: -0.38280000000000003), CGPoint(x: -0.00253, y: -0.3712500000000001), CGPoint(x: 0.00011000000000000002, y: -0.36982000000000004),
            CGPoint(x: 0.0027500000000000003, y: -0.36839), CGPoint(x: 0.0061600000000000005, y: -0.36630000000000007), CGPoint(x: 0.0088, y: -0.36487), CGPoint(x: 0.011330000000000002, y: -0.36322000000000004),
            CGPoint(x: 0.013750000000000002, y: -0.38313), CGPoint(x: 0.016280000000000003, y: -0.39787000000000006), CGPoint(x: 0.01958, y: -0.41239000000000003), CGPoint(x: 0.02508, y: -0.4310900000000001),
            CGPoint(x: 0.029920000000000002, y: -0.44462), CGPoint(x: 0.03531, y: -0.4576), CGPoint(x: 0.04136000000000001, y: -0.4697), CGPoint(x: 0.05016, y: -0.48411000000000004), CGPoint(x: 0.057420000000000006, y: -0.49357),
            CGPoint(x: 0.06468, y: -0.5000600000000001), CGPoint(x: 0.07392, y: -0.50248), CGPoint(x: 0.08096, y: -0.50336), CGPoint(x: 0.08800000000000001, y: -0.5032500000000001), CGPoint(x: 0.09735, y: -0.50182),
            CGPoint(x: 0.10659, y: -0.49896000000000007), CGPoint(x: 0.11649, y: -0.49434000000000006), CGPoint(x: 0.1287, y: -0.4862), CGPoint(x: 0.13706000000000002, y: -0.47872000000000003), CGPoint(x: 0.14476, y: -0.46992000000000006),
            CGPoint(x: 0.15345000000000003, y: -0.45738000000000006), CGPoint(x: 0.15906, y: -0.44715), CGPoint(x: 0.16401000000000002, y: -0.43604), CGPoint(x: 0.16984000000000002, y: -0.41976),
            CGPoint(x: 0.17347, y: -0.40656000000000003), CGPoint(x: 0.17853000000000002, y: -0.3806), CGPoint(x: 0.18249, y: -0.34144), CGPoint(x: 0.18315000000000003, y: -0.30899), CGPoint(x: 0.18194000000000002, y: -0.27379000000000003),
            CGPoint(x: 0.17886000000000002, y: -0.23606000000000002), CGPoint(x: 0.17941000000000001, y: -0.23562000000000002), CGPoint(x: 0.17996, y: -0.23529000000000003), CGPoint(x: 0.18040000000000003, y: -0.23496000000000003),
            CGPoint(x: 0.18095000000000003, y: -0.23441000000000004), CGPoint(x: 0.18139, y: -0.23419000000000004), CGPoint(x: 0.18172000000000002, y: -0.23397), CGPoint(x: 0.18205000000000002, y: -0.23364000000000001),
            CGPoint(x: 0.18227, y: -0.23353000000000002), CGPoint(x: 0.18249, y: -0.23331000000000002), CGPoint(x: 0.20702000000000004, y: -0.21109), CGPoint(x: 0.22275000000000003, y: -0.19184),
            CGPoint(x: 0.23606000000000002, y: -0.17072), CGPoint(x: 0.25014000000000003, y: -0.13981), CGPoint(x: 0.25905, y: -0.11033000000000001), CGPoint(x: 0.26521000000000006, y: -0.0704),
            CGPoint(x: 0.26389, y: -0.018150000000000003), CGPoint(x: 0.25608000000000003, y: 0.018150000000000003), CGPoint(x: 0.24266000000000001, y: 0.049830000000000006), CGPoint(x: 0.23045000000000002, y: 0.06798000000000001),
            CGPoint(x: 0.23023000000000005, y: 0.06831000000000001), CGPoint(x: 0.23001000000000002, y: 0.06842000000000001), CGPoint(x: 0.22979000000000002, y: 0.06886), CGPoint(x: 0.23683, y: 0.08239),
            CGPoint(x: 0.24585, y: 0.10285000000000001), CGPoint(x: 0.25322, y: 0.12375000000000001), CGPoint(x: 0.26015, y: 0.15213000000000002), CGPoint(x: 0.26312, y: 0.1738), CGPoint(x: 0.26378, y: 0.18139),
            CGPoint(x: 0.26378, y: 0.18183000000000002), CGPoint(x: 0.26378, y: 0.18216000000000002), CGPoint(x: 0.26389, y: 0.18249), CGPoint(x: 0.26323, y: 0.21989), CGPoint(x: 0.25883, y: 0.24805000000000002),
            CGPoint(x: 0.25124, y: 0.27599), CGPoint(x: 0.23573, y: 0.31317000000000006), CGPoint(x: 0.22572, y: 0.33176), CGPoint(x: 0.22561000000000003, y: 0.33198000000000005), CGPoint(x: 0.2255, y: 0.33242000000000005),
            CGPoint(x: 0.22572, y: 0.33275), CGPoint(x: 0.22583000000000003, y: 0.33308000000000004), CGPoint(x: 0.23353000000000002, y: 0.35365), CGPoint(x: 0.24211000000000002, y: 0.38412), CGPoint(x: 0.24761000000000002, y: 0.4147),
            CGPoint(x: 0.24992000000000003, y: 0.4555100000000001), CGPoint(x: 0.24783000000000002, y: 0.4862), CGPoint(x: 0.24640000000000004, y: 0.4965400000000001), CGPoint(x: 0.24629, y: 0.49698000000000003),
            CGPoint(x: 0.24629, y: 0.49742000000000003), CGPoint(x: 0.24618, y: 0.4977500000000001), CGPoint(x: 0.24618, y: 0.49808), CGPoint(x: 0.24893, y: 0.47102000000000005), CGPoint(x: 0.24849000000000002, y: 0.44374),
            CGPoint(x: 0.24486000000000002, y: 0.41635000000000005), CGPoint(x: 0.23496000000000003, y: 0.37972000000000006), CGPoint(x: 0.22363000000000002, y: 0.35211000000000003), CGPoint(x: 0.22385, y: 0.35189000000000004),
            CGPoint(x: 0.24200000000000002, y: 0.31955), CGPoint(x: 0.25157, y: 0.29557), CGPoint(x: 0.25795, y: 0.27181), CGPoint(x: 0.26158000000000003, y: 0.24024000000000004), CGPoint(x: 0.2607, y: 0.21780000000000002),
            CGPoint(x: 0.25762, y: 0.19745000000000001), CGPoint(x: 0.25014000000000003, y: 0.17061), CGPoint(x: 0.24200000000000002, y: 0.15070000000000003), CGPoint(x: 0.23177, y: 0.13123),
            CGPoint(x: 0.22407000000000002, y: 0.11825000000000001), CGPoint(x: 0.22418000000000002, y: 0.11803000000000001), CGPoint(x: 0.22847, y: 0.11473000000000001), CGPoint(x: 0.23650000000000002, y: 0.10505),
            CGPoint(x: 0.24189000000000002, y: 0.09537000000000001), CGPoint(x: 0.24651, y: 0.08371), CGPoint(x: 0.25036, y: 0.0704), CGPoint(x: 0.24519000000000002, y: 0.047850000000000004), CGPoint(x: 0.23727, y: 0.031240000000000004),
            CGPoint(x: 0.22781, y: 0.01617), CGPoint(x: 0.21274, y: -0.0016500000000000002), CGPoint(x: 0.19976000000000002, y: -0.013090000000000003), CGPoint(x: 0.18315000000000003, y: -0.023870000000000002),
            CGPoint(x: 0.15796000000000002, y: -0.03443), CGPoint(x: 0.13684000000000002, y: -0.039490000000000004), CGPoint(x: 0.11363000000000001, y: -0.04191), CGPoint(x: 0.08558, y: -0.0473),
            CGPoint(x: 0.07612000000000001, y: -0.06325000000000001), CGPoint(x: 0.06545000000000001, y: -0.07733000000000001), CGPoint(x: 0.049060000000000006, y: -0.09328), CGPoint(x: 0.03542, y: -0.10318000000000001),
            CGPoint(x: 0.014740000000000001, y: -0.10758000000000001), CGPoint(x: -0.02607, y: -0.09669000000000001), CGPoint(x: -0.05291, y: -0.08305), CGPoint(x: -0.07524000000000002, y: -0.06556000000000001),
            CGPoint(x: -0.09603, y: -0.03751), CGPoint(x: -0.11748000000000001, y: -0.02926), CGPoint(x: -0.14278000000000002, y: -0.026510000000000002), CGPoint(x: -0.16577, y: -0.02134),
            CGPoint(x: -0.19294000000000003, y: -0.011000000000000001), CGPoint(x: -0.21065000000000003, y: -0.0008800000000000001), CGPoint(x: -0.22484, y: 0.01012), CGPoint(x: -0.24024000000000004, y: 0.026510000000000002),
            CGPoint(x: -0.24981, y: 0.040260000000000004), CGPoint(x: -0.25784, y: 0.055330000000000004), CGPoint(x: -0.26587, y: 0.07722000000000001), CGPoint(x: -0.26246, y: 0.09141), CGPoint(x: -0.25806, y: 0.10439000000000001),
            CGPoint(x: -0.25102, y: 0.11957000000000001), CGPoint(x: -0.24508000000000002, y: 0.12903), CGPoint(x: -0.23870000000000002, y: 0.13662000000000002), CGPoint(x: -0.23848, y: 0.13684000000000002),
            CGPoint(x: -0.23826, y: 0.13695000000000002), CGPoint(x: -0.23353000000000002, y: 0.14289), CGPoint(x: -0.22990000000000002, y: 0.15202), CGPoint(x: -0.22913000000000003, y: 0.15939),
            CGPoint(x: -0.23023000000000005, y: 0.16665000000000002), CGPoint(x: -0.23628000000000002, y: 0.17930000000000001), CGPoint(x: -0.24497000000000002, y: 0.19789), CGPoint(x: -0.25234, y: 0.21868),
            CGPoint(x: -0.25828, y: 0.24101), CGPoint(x: -0.26345, y: 0.27214000000000005), CGPoint(x: -0.26499, y: 0.29667000000000004), CGPoint(x: -0.26389, y: 0.32219000000000003), CGPoint(x: -0.25806, y: 0.35376),
            CGPoint(x: -0.25036, y: 0.37532000000000004), CGPoint(x: -0.2398, y: 0.39468000000000003), CGPoint(x: -0.23089, y: 0.40656000000000003), CGPoint(x: -0.23067000000000001, y: 0.40678000000000003),
            CGPoint(x: -0.23056000000000001, y: 0.40700000000000003), CGPoint(x: -0.23518, y: 0.41800000000000004), CGPoint(x: -0.24706, y: 0.44869000000000003), CGPoint(x: -0.25509000000000004, y: 0.47729000000000005),
            CGPoint(x: -0.25993000000000005, y: 0.5119400000000001), CGPoint(x: -0.25916, y: 0.5354800000000001), CGPoint(x: -0.2585, y: 0.54098), CGPoint(x: -0.26169000000000003, y: 0.50336), CGPoint(x: -0.25949, y: 0.47344),
            CGPoint(x: -0.25333, y: 0.44198000000000004), CGPoint(x: -0.23914000000000002, y: 0.39787000000000006), CGPoint(x: -0.23441000000000004, y: 0.38621000000000005), CGPoint(x: -0.2343, y: 0.38588000000000006),
            CGPoint(x: -0.23408, y: 0.38544), CGPoint(x: -0.23397, y: 0.38522000000000006), CGPoint(x: -0.23386000000000004, y: 0.38489), CGPoint(x: -0.23397, y: 0.38456000000000007), CGPoint(x: -0.23419000000000004, y: 0.38423),
            CGPoint(x: -0.2343, y: 0.3840100000000001), CGPoint(x: -0.2343, y: 0.38368), CGPoint(x: -0.23441000000000004, y: 0.38335), CGPoint(x: -0.23232000000000003, y: 0.35937), CGPoint(x: -0.22858000000000003, y: 0.3355),
            CGPoint(x: -0.22110000000000002, y: 0.3047), CGPoint(x: -0.21384, y: 0.2827), CGPoint(x: -0.20537000000000002, y: 0.26224000000000003), CGPoint(x: -0.20515000000000003, y: 0.26191000000000003),
            CGPoint(x: -0.20504000000000003, y: 0.26169000000000003), CGPoint(x: -0.20493, y: 0.26136000000000004), CGPoint(x: -0.20482000000000003, y: 0.26092000000000004), CGPoint(x: -0.21219000000000002, y: 0.24937000000000004),
            CGPoint(x: -0.21868, y: 0.23672), CGPoint(x: -0.22616000000000003, y: 0.21846000000000002), CGPoint(x: -0.23067000000000001, y: 0.20394000000000004), CGPoint(x: -0.2343, y: 0.18865000000000004),
            CGPoint(x: -0.23441000000000004, y: 0.18821000000000002), CGPoint(x: -0.23452, y: 0.18788000000000002), CGPoint(x: -0.23452, y: 0.18755000000000002), CGPoint(x: -0.22638000000000003, y: 0.16412000000000002),
            CGPoint(x: -0.21175000000000002, y: 0.13519), CGPoint(x: -0.19778, y: 0.11539), CGPoint(x: -0.18150000000000002, y: 0.09735), CGPoint(x: -0.16225, y: 0.08096), CGPoint(x: -0.1606, y: 0.07975), CGPoint(x: -0.15895, y: 0.07865),
            CGPoint(x: -0.15675, y: 0.07711), CGPoint(x: -0.1551, y: 0.07590000000000001), CGPoint(x: -0.15532, y: 0.06226), CGPoint(x: -0.15829000000000001, y: 0.01331), CGPoint(x: -0.15829000000000001, y: -0.02035),
            CGPoint(x: -0.15631, y: -0.05126000000000001), CGPoint(x: -0.15070000000000003, y: -0.08800000000000001), CGPoint(x: -0.14641, y: -0.10538), CGPoint(x: -0.14245000000000002, y: -0.11792000000000001),
            CGPoint(x: -0.13607000000000002, y: -0.13343000000000002), CGPoint(x: -0.13068000000000002, y: -0.14399), CGPoint(x: -0.12463, y: -0.15367), CGPoint(x: -0.11506000000000001, y: -0.16577),
            CGPoint(x: -0.10692, y: -0.17369000000000004), CGPoint(x: -0.09801, y: -0.18040000000000003), CGPoint(x: -0.08855, y: -0.18590000000000004), CGPoint(x: -0.07502, y: -0.19107000000000002),
            CGPoint(x: -0.06798000000000001, y: -0.19261000000000003), CGPoint(x: -0.06094, y: -0.19327), CGPoint(x: -0.051590000000000004, y: -0.19272), CGPoint(x: -0.044550000000000006, y: -0.19140000000000001),
            CGPoint(x: -0.03773, y: -0.18909), CGPoint(x: -0.07821, y: -0.27940000000000004), CGPoint(x: -0.10857, y: -0.34705), CGPoint(x: -0.13893, y: -0.4147), CGPoint(x: -0.17941000000000001, y: -0.5049),
            CGPoint(x: -0.00715, y: -0.12485000000000002), CGPoint(x: 0.017050000000000003, y: -0.12331000000000002), CGPoint(x: 0.047740000000000005, y: -0.11682000000000001), CGPoint(x: 0.0693, y: -0.10868000000000001),
            CGPoint(x: 0.09537000000000001, y: -0.09383000000000001), CGPoint(x: 0.11264000000000002, y: -0.08019000000000001), CGPoint(x: 0.12694000000000003, y: -0.0649), CGPoint(x: 0.14179, y: -0.04268),
            CGPoint(x: 0.14926999999999999, y: -0.02486), CGPoint(x: 0.15400000000000003, y: -0.00033), CGPoint(x: 0.15334, y: 0.02101), CGPoint(x: 0.14883000000000002, y: 0.04202), CGPoint(x: 0.13695000000000002, y: 0.06677),
            CGPoint(x: 0.12386000000000001, y: 0.08272000000000002), CGPoint(x: 0.10120000000000001, y: 0.10043000000000002), CGPoint(x: 0.08393000000000002, y: 0.10934), CGPoint(x: 0.06468, y: 0.11638000000000001),
            CGPoint(x: 0.036300000000000006, y: 0.12287000000000001), CGPoint(x: 0.01331, y: 0.12551), CGPoint(x: -0.01111, y: 0.12650000000000003), CGPoint(x: -0.04521, y: 0.12419000000000001), CGPoint(x: -0.06875, y: 0.11968000000000001),
            CGPoint(x: -0.09735, y: 0.10989000000000002), CGPoint(x: -0.11627000000000001, y: 0.09999), CGPoint(x: -0.13299, y: 0.08789000000000001), CGPoint(x: -0.15103000000000003, y: 0.06908),
            CGPoint(x: -0.16104000000000002, y: 0.05324), CGPoint(x: -0.16984000000000002, y: 0.03036), CGPoint(x: -0.17259000000000002, y: 0.0121), CGPoint(x: -0.17193, y: -0.00649), CGPoint(x: -0.16522, y: -0.030910000000000003),
            CGPoint(x: -0.15631, y: -0.048510000000000005), CGPoint(x: -0.13937000000000002, y: -0.0704), CGPoint(x: -0.12342, y: -0.08514000000000001), CGPoint(x: -0.10483, y: -0.09812000000000001),
            CGPoint(x: -0.07733000000000001, y: -0.11176), CGPoint(x: -0.05489, y: -0.11891000000000002), CGPoint(x: -0.023430000000000003, y: -0.12419000000000001), CGPoint(x: -0.00715, y: -0.08294),
            CGPoint(x: -0.021560000000000003, y: -0.0693), CGPoint(x: -0.03212, y: -0.054560000000000004), CGPoint(x: -0.03751, y: -0.043230000000000005), CGPoint(x: -0.040810000000000006, y: -0.028160000000000004),
            CGPoint(x: -0.03993, y: -0.013420000000000001), CGPoint(x: -0.03542, y: 0.0007700000000000001), CGPoint(x: -0.027280000000000002, y: 0.01397), CGPoint(x: -0.019030000000000002, y: 0.02299), CGPoint(x: -0.00396, y: 0.03432),
            CGPoint(x: 0.015620000000000002, y: 0.043780000000000006), CGPoint(x: 0.038500000000000006, y: 0.05038), CGPoint(x: 0.06446, y: 0.053680000000000005), CGPoint(x: 0.08536, y: 0.05412000000000001),
            CGPoint(x: 0.11165000000000001, y: 0.05214), CGPoint(x: 0.13519, y: 0.047740000000000005), CGPoint(x: 0.15565, y: 0.04092), CGPoint(x: 0.16885, y: 0.034210000000000004), CGPoint(x: 0.18304, y: 0.02332),
            CGPoint(x: 0.19327, y: 0.0099), CGPoint(x: 0.19943, y: -0.005940000000000001), CGPoint(x: 0.20152, y: -0.024530000000000003), CGPoint(x: 0.20031000000000002, y: -0.03586), CGPoint(x: 0.19514, y: -0.05115),
            CGPoint(x: 0.18612, y: -0.06611), CGPoint(x: 0.17336000000000001, y: -0.08008000000000001), CGPoint(x: 0.15609, y: -0.09306), CGPoint(x: 0.14102000000000003, y: -0.10109),
            CGPoint(x: 0.11891000000000002, y: -0.10890000000000001), CGPoint(x: 0.09493000000000001, y: -0.11286), CGPoint(x: 0.07128, y: -0.10956), CGPoint(x: 0.04884000000000001, y: -0.10197000000000002),
            CGPoint(x: 0.032010000000000004, y: -0.09625), CGPoint(x: 0.00957, y: -0.08866000000000002), CGPoint(x: 0.023760000000000003, y: -0.026400000000000003), CGPoint(x: 0.024970000000000003, y: -0.02486),
            CGPoint(x: 0.027280000000000002, y: -0.018920000000000003), CGPoint(x: 0.02739, y: -0.014190000000000001), CGPoint(x: 0.02552, y: -0.00825), CGPoint(x: 0.022660000000000003, y: -0.0044),
            CGPoint(x: 0.018810000000000004, y: -0.0012100000000000001), CGPoint(x: 0.016280000000000003, y: 0.0007700000000000001), CGPoint(x: 0.012870000000000001, y: 0.0034100000000000003), CGPoint(x: 0.01023, y: 0.0055000000000000005),
            CGPoint(x: 0.007700000000000001, y: 0.0074800000000000005), CGPoint(x: 0.007700000000000001, y: 0.012650000000000002), CGPoint(x: 0.007700000000000001, y: 0.016610000000000003),
            CGPoint(x: 0.007700000000000001, y: 0.021780000000000004), CGPoint(x: 0.007700000000000001, y: 0.025740000000000002), CGPoint(x: 0.007700000000000001, y: 0.025630000000000003),
            CGPoint(x: 0.007700000000000001, y: 0.021670000000000002), CGPoint(x: 0.007700000000000001, y: 0.016280000000000003), CGPoint(x: 0.007700000000000001, y: 0.012210000000000002),
            CGPoint(x: 0.007700000000000001, y: 0.0068200000000000005), CGPoint(x: 0.00528, y: 0.00495), CGPoint(x: 0.0029700000000000004, y: 0.0029700000000000004), CGPoint(x: -0.00022000000000000003, y: 0.00044000000000000007),
            CGPoint(x: -0.00264, y: -0.00143), CGPoint(x: -0.0044, y: -0.00286), CGPoint(x: -0.0024200000000000003, y: -0.00132), CGPoint(x: 0.0, y: 0.00066), CGPoint(x: 0.00198, y: 0.0022), CGPoint(x: 0.0044, y: 0.0041800000000000006),
            CGPoint(x: 0.00638, y: 0.0036300000000000004), CGPoint(x: 0.00825, y: 0.0020900000000000003), CGPoint(x: 0.010890000000000002, y: 0.00011000000000000002), CGPoint(x: 0.01276, y: -0.00143),
            CGPoint(x: 0.015400000000000002, y: -0.0034100000000000003), CGPoint(x: 0.01694, y: -0.007810000000000001), CGPoint(x: 0.019030000000000002, y: -0.013530000000000002), CGPoint(x: 0.020680000000000004, y: -0.01782),
            CGPoint(x: 0.022770000000000002, y: -0.023540000000000002), CGPoint(x: -0.21197000000000002, y: -0.11616000000000001), CGPoint(x: -0.20779000000000003, y: -0.11594), CGPoint(x: -0.19987000000000002, y: -0.11429000000000002),
            CGPoint(x: -0.19613, y: -0.11297000000000001), CGPoint(x: -0.18931, y: -0.10912000000000001), CGPoint(x: -0.18612, y: -0.10681000000000002), CGPoint(x: -0.18326, y: -0.10417000000000001),
            CGPoint(x: -0.17831, y: -0.09812000000000001), CGPoint(x: -0.17633000000000001, y: -0.09482), CGPoint(x: -0.17457000000000003, y: -0.0913), CGPoint(x: -0.17226, y: -0.08360000000000001), CGPoint(x: -0.1716, y: -0.07953),
            CGPoint(x: -0.17138, y: -0.07535000000000001), CGPoint(x: -0.17644, y: -0.08052000000000001), CGPoint(x: -0.17897000000000002, y: -0.08305), CGPoint(x: -0.18403000000000003, y: -0.08811000000000001),
            CGPoint(x: -0.18656, y: -0.09064000000000001), CGPoint(x: -0.18909, y: -0.09317), CGPoint(x: -0.19415000000000002, y: -0.09834), CGPoint(x: -0.19668, y: -0.10087000000000002),
            CGPoint(x: -0.20174000000000003, y: -0.10593000000000001), CGPoint(x: -0.20438, y: -0.10846), CGPoint(x: -0.20691, y: -0.11099000000000002), CGPoint(x: -0.21197000000000002, y: -0.11616000000000001),
            CGPoint(x: 0.19525, y: -0.11616000000000001), CGPoint(x: 0.19943, y: -0.11594), CGPoint(x: 0.20735, y: -0.11429000000000002), CGPoint(x: 0.21109, y: -0.11297000000000001),
            CGPoint(x: 0.21791000000000002, y: -0.10912000000000001), CGPoint(x: 0.22110000000000002, y: -0.10681000000000002), CGPoint(x: 0.22396000000000002, y: -0.10417000000000001),
            CGPoint(x: 0.22891000000000003, y: -0.09812000000000001), CGPoint(x: 0.23089, y: -0.09482), CGPoint(x: 0.23265000000000002, y: -0.0913), CGPoint(x: 0.23496000000000003, y: -0.08360000000000001),
            CGPoint(x: 0.23562000000000002, y: -0.07953), CGPoint(x: 0.23584000000000002, y: -0.07535000000000001), CGPoint(x: 0.23078, y: -0.08052000000000001), CGPoint(x: 0.22825, y: -0.08305),
            CGPoint(x: 0.22319000000000003, y: -0.08811000000000001), CGPoint(x: 0.22066000000000002, y: -0.09064000000000001), CGPoint(x: 0.21802, y: -0.09317), CGPoint(x: 0.21296, y: -0.09834),
            CGPoint(x: 0.21043, y: -0.10087000000000002), CGPoint(x: 0.20537000000000002, y: -0.10593000000000001), CGPoint(x: 0.20284000000000002, y: -0.10846), CGPoint(x: 0.20031000000000002, y: -0.11099000000000002),
            CGPoint(x: 0.19525, y: -0.11616000000000001), CGPoint(x: -0.22143000000000002, y: -0.49346000000000007), CGPoint(x: -0.22165000000000004, y: -0.49324000000000007), CGPoint(x: -0.22176, y: -0.49313),
            CGPoint(x: -0.22418000000000002, y: -0.48950000000000005), CGPoint(x: -0.22759000000000001, y: -0.48356000000000005), CGPoint(x: -0.23078, y: -0.47663000000000005), CGPoint(x: -0.23276000000000002, y: -0.47157000000000004),
            CGPoint(x: -0.23551000000000002, y: -0.46332000000000007), CGPoint(x: -0.23804000000000003, y: -0.45408000000000004), CGPoint(x: -0.24189000000000002, y: -0.43472000000000005), CGPoint(x: -0.24376, y: -0.42042),
            CGPoint(x: -0.24552000000000004, y: -0.3971), CGPoint(x: -0.24607000000000004, y: -0.37158), CGPoint(x: -0.24563000000000001, y: -0.35321), CGPoint(x: -0.24387000000000003, y: -0.32406),
            CGPoint(x: -0.23232000000000003, y: -0.32714000000000004), CGPoint(x: -0.22044000000000002, y: -0.32978), CGPoint(x: -0.21241000000000002, y: -0.33132000000000006), CGPoint(x: -0.19987000000000002, y: -0.33308000000000004),
            CGPoint(x: -0.18700000000000003, y: -0.33451000000000003), CGPoint(x: -0.17809, y: -0.33506), CGPoint(x: -0.17798000000000003, y: -0.3351700000000001), CGPoint(x: -0.17765000000000003, y: -0.33528),
            CGPoint(x: -0.17754, y: -0.3355), CGPoint(x: -0.17743, y: -0.3357200000000001), CGPoint(x: -0.17721, y: -0.33605), CGPoint(x: -0.1771, y: -0.33638000000000007), CGPoint(x: -0.17688, y: -0.33671),
            CGPoint(x: -0.17600000000000002, y: -0.33814000000000005), CGPoint(x: -0.17479000000000003, y: -0.34034000000000003), CGPoint(x: -0.17347, y: -0.34243000000000007), CGPoint(x: -0.17270000000000002, y: -0.34375),
            CGPoint(x: -0.17127, y: -0.34584000000000004), CGPoint(x: -0.16995000000000002, y: -0.3479300000000001), CGPoint(x: -0.16775, y: -0.36883), CGPoint(x: -0.16753, y: -0.38335), CGPoint(x: -0.16885, y: -0.40535000000000004),
            CGPoint(x: -0.17215000000000003, y: -0.42735000000000006), CGPoint(x: -0.17732000000000003, y: -0.44869000000000003), CGPoint(x: -0.18172000000000002, y: -0.4622200000000001), CGPoint(x: -0.18546, y: -0.47135000000000005),
            CGPoint(x: -0.18931, y: -0.47971), CGPoint(x: -0.19195, y: -0.48477000000000003), CGPoint(x: -0.19602, y: -0.49148000000000003), CGPoint(x: -0.20020000000000002, y: -0.4970900000000001),
            CGPoint(x: -0.20416, y: -0.49984000000000006), CGPoint(x: -0.20647000000000001, y: -0.49896000000000007), CGPoint(x: -0.20988, y: -0.4976400000000001), CGPoint(x: -0.21329, y: -0.49643000000000004),
            CGPoint(x: -0.21681, y: -0.49511000000000005), CGPoint(x: -0.21912, y: -0.49423), CGPoint(x: 0.20768, y: -0.4915900000000001), CGPoint(x: 0.20614000000000002, y: -0.49005000000000004),
            CGPoint(x: 0.20339000000000002, y: -0.4866400000000001), CGPoint(x: 0.19932000000000002, y: -0.4805900000000001), CGPoint(x: 0.19514, y: -0.47355), CGPoint(x: 0.1925, y: -0.4682700000000001),
            CGPoint(x: 0.18876, y: -0.45958000000000004), CGPoint(x: 0.18634, y: -0.45342000000000005), CGPoint(x: 0.17974, y: -0.4317500000000001), CGPoint(x: 0.17501, y: -0.40887), CGPoint(x: 0.17314000000000002, y: -0.39336),
            CGPoint(x: 0.17215000000000003, y: -0.37004), CGPoint(x: 0.17336000000000001, y: -0.34749), CGPoint(x: 0.17556, y: -0.33308000000000004), CGPoint(x: 0.17611000000000002, y: -0.33231),
            CGPoint(x: 0.17666, y: -0.33143000000000006), CGPoint(x: 0.17699, y: -0.33088000000000006), CGPoint(x: 0.17743, y: -0.33), CGPoint(x: 0.17776, y: -0.32945), CGPoint(x: 0.17831, y: -0.32857000000000003),
            CGPoint(x: 0.17853000000000002, y: -0.32824000000000003), CGPoint(x: 0.17864, y: -0.32813000000000003), CGPoint(x: 0.17875000000000002, y: -0.32791), CGPoint(x: 0.17908000000000002, y: -0.32791),
            CGPoint(x: 0.17930000000000001, y: -0.32791), CGPoint(x: 0.17963, y: -0.32791), CGPoint(x: 0.17996, y: -0.32791), CGPoint(x: 0.18073000000000003, y: -0.3377), CGPoint(x: 0.18194000000000002, y: -0.36553),
            CGPoint(x: 0.18183000000000002, y: -0.39127000000000006), CGPoint(x: 0.18106, y: -0.40722), CGPoint(x: 0.17886000000000002, y: -0.42933), CGPoint(x: 0.17677000000000004, y: -0.44286000000000003),
            CGPoint(x: 0.17325000000000002, y: -0.45837000000000006), CGPoint(x: 0.17072, y: -0.46728000000000003), CGPoint(x: 0.16885, y: -0.47278000000000003), CGPoint(x: 0.16577, y: -0.48015),
            CGPoint(x: 0.16247, y: -0.48675000000000007), CGPoint(x: 0.16016000000000002, y: -0.49060000000000004), CGPoint(x: 0.15774000000000002, y: -0.49423), CGPoint(x: 0.15752, y: -0.49445000000000006),
            CGPoint(x: 0.16049000000000002, y: -0.49423), CGPoint(x: 0.16995000000000002, y: -0.49368), CGPoint(x: 0.17622000000000002, y: -0.49335000000000007), CGPoint(x: 0.18568, y: -0.49280000000000007),
            CGPoint(x: 0.19503000000000004, y: -0.4922500000000001), CGPoint(x: 0.2013, y: -0.49192)
        ]
        let denominator = max(1, coords.count - 1)
        return coords.enumerated().map { index, pt in
            ShapePoint(
                point: pt,
                role: index.isMultiple(of: 3) ? "logo-flame-spark" : "logo-flame-inner",
                progress: Double(index) / Double(denominator)
            )
        }
    }

    static func generateFactoryLogoPoints() -> [ShapePoint] {
        SwarmProviderLogoDotMap.factory().map {
            ShapePoint(point: $0.point, role: $0.role, progress: $0.progress)
        }
    }

    static func generateHermesLogoPoints() -> [ShapePoint] {
        SwarmProviderLogoDotMap.hermesAgent().map {
            ShapePoint(point: $0.point, role: $0.role, progress: $0.progress)
        }
    }

    static func generateGrokLogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        func appendArc(radius: Double, start: Double, end: Double, count: Int, role: String) {
            for i in 0..<count {
                let t = Double(i) / Double(max(count - 1, 1))
                let angle = start + (end - start) * t
                pts.append(ShapePoint(
                    point: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius),
                    role: role,
                    progress: t
                ))
            }
        }

        appendArc(radius: 0.34, start: 0.70, end: 2.85, count: 130, role: "logo-flame-outer")
        appendArc(radius: 0.23, start: 0.80, end: 2.65, count: 95, role: "logo-flame-inner")
        appendArc(radius: 0.34, start: 3.65, end: 6.02, count: 145, role: "logo-flame-outer")
        appendArc(radius: 0.23, start: 3.90, end: 5.78, count: 95, role: "logo-flame-inner")

        let slashCount = 180
        for i in 0..<slashCount {
            let t = Double(i) / Double(max(slashCount - 1, 1))
            let x = -0.42 + t * 0.84
            let y = 0.40 - t * 0.82
            let normal = 0.018
            for lane in [-1.0, 0.0, 1.0] {
                pts.append(ShapePoint(
                    point: CGPoint(x: x + lane * normal, y: y + lane * normal * 0.45),
                    role: lane == 0 ? "logo-flame-spark" : "logo-flame-inner",
                    progress: t
                ))
            }
        }
        return pts
    }

    static func generateCodexLogoPoints() -> [ShapePoint] {
        let leftBrace = [
            CGPoint(x: -0.06, y: 0.28),
            CGPoint(x: -0.18, y: 0.26),
            CGPoint(x: -0.16, y: 0.12),
            CGPoint(x: -0.28, y: 0.0),
            CGPoint(x: -0.16, y: -0.12),
            CGPoint(x: -0.18, y: -0.26),
            CGPoint(x: -0.06, y: -0.28)
        ]
        let rightBrace = [
            CGPoint(x: 0.06, y: 0.28),
            CGPoint(x: 0.18, y: 0.26),
            CGPoint(x: 0.16, y: 0.12),
            CGPoint(x: 0.28, y: 0.0),
            CGPoint(x: 0.16, y: -0.12),
            CGPoint(x: 0.18, y: -0.26),
            CGPoint(x: 0.06, y: -0.28)
        ]
        let leftPts = generateSplinePoints(controlPoints: leftBrace, stepsPerSegment: 50, role: "logo-flame-outer")
        let rightPts = generateSplinePoints(controlPoints: rightBrace, stepsPerSegment: 50, role: "logo-flame-inner")
        return leftPts + rightPts
    }

    static func generateAntigravityLogoPoints() -> [ShapePoint] {
        let diamond = [
            CGPoint(x: 0.0, y: 0.32),
            CGPoint(x: 0.24, y: 0.0),
            CGPoint(x: 0.0, y: -0.32),
            CGPoint(x: -0.24, y: 0.0)
        ]
        let triangle = [
            CGPoint(x: 0.0, y: 0.12),
            CGPoint(x: 0.10, y: -0.08),
            CGPoint(x: -0.10, y: -0.08)
        ]
        let diamondPts = generateSplinePoints(controlPoints: diamond, stepsPerSegment: 60, role: "logo-flame-outer")
        let trianglePts = generateSplinePoints(controlPoints: triangle, stepsPerSegment: 60, role: "logo-flame-inner")
        return diamondPts + trianglePts
    }
}
