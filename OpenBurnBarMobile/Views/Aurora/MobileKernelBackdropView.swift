import SwiftUI
import OpenBurnBarCore

struct MobileKernelBackdropView: View {
    let kernel: MobileBackdropKernel
    let accent: Color
    var visibility: MobileBackgroundVisibility = .prominent
    var colorDriver: SwarmColorDriver?
    var backdropColors: [Color]?
    var maxFrameRate: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fps = Self.sanitizedFrameRate(maxFrameRate)
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: reduceMotion)) { timeline in
            Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                MobileKernelBackdropRenderer.draw(
                    kernel: kernel,
                    accent: accent,
                    time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                    opacity: opacity,
                    colorDriver: colorDriver,
                    backdropColors: backdropColors,
                    size: size,
                    context: &context
                )
            }
            .ignoresSafeArea()
        }
    }

    nonisolated static func sanitizedFrameRate(_ maxFrameRate: Double?) -> Double {
        guard let maxFrameRate, maxFrameRate.isFinite, maxFrameRate > 0 else { return 30 }
        return max(1, min(maxFrameRate, 30))
    }

    private var opacity: Double {
        switch visibility {
        case .prominent: return 1
        case .subtle: return 0.72
        case .obscured: return 0.5
        case .hidden: return 0
        }
    }
}

struct MobileKernelBackdropFrameView: View {
    let kernel: MobileBackdropKernel
    let accent: Color
    let time: TimeInterval
    let size: CGSize
    var colorDriver: SwarmColorDriver?
    var backdropColors: [Color]?

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, canvasSize in
            MobileKernelBackdropRenderer.draw(
                kernel: kernel,
                accent: accent,
                time: time,
                opacity: 1,
                colorDriver: colorDriver,
                backdropColors: backdropColors,
                size: canvasSize,
                context: &context
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

private enum MobileKernelBackdropRenderer {
    static func draw(
        kernel: MobileBackdropKernel,
        accent: Color,
        time: TimeInterval,
        opacity: Double,
        colorDriver: SwarmColorDriver?,
        backdropColors: [Color]?,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: palette(for: kernel, accent: accent, colorDriver: colorDriver, backdropColors: backdropColors)),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: size.height)
        ))

        switch kernel.rendererFamily {
        case .constellation:
            drawConstellation(time: time, opacity: opacity, size: size, context: &context)
        case .flow:
            drawFlow(time: time, opacity: opacity, size: size, context: &context)
        case .ribbons:
            drawRibbons(time: time, opacity: opacity, size: size, context: &context, kernel: kernel)
        case .orbs:
            drawOrbs(time: time, opacity: opacity, size: size, context: &context, kernel: kernel)
        case .lattice:
            drawLattice(time: time, opacity: opacity, size: size, context: &context, kernel: kernel)
        case .clouds:
            drawClouds(time: time, opacity: opacity, size: size, context: &context, kernel: kernel)
        case .bloom:
            drawBloom(time: time, opacity: opacity, size: size, context: &context)
        case .crystal:
            drawCrystal(time: time, opacity: opacity, size: size, context: &context)
        case .mycelium:
            drawMycelium(time: time, opacity: opacity, size: size, context: &context)
        case .marble:
            drawMarble(time: time, opacity: opacity, size: size, context: &context, kernel: kernel)
        case .beam:
            drawBeam(time: time, opacity: opacity, size: size, context: &context)
        case .storm:
            drawStorm(time: time, opacity: opacity, size: size, context: &context)
        case .plasma:
            drawPlasma(time: time, opacity: opacity, size: size, context: &context)
        case .paper:
            drawPaper(time: time, opacity: opacity, size: size, context: &context)
        }

        context.fill(Path(rect), with: .color(.black.opacity(kernel.readabilityScrim * opacity)))
    }

    private static func palette(
        for kernel: MobileBackdropKernel,
        accent: Color,
        colorDriver: SwarmColorDriver?,
        backdropColors: [Color]?
    ) -> [Color] {
        if let dataPalette = dataDrivenPalette(for: colorDriver, accent: accent) {
            return dataPalette
        }
        if let backdropColors, backdropColors.count >= 2 {
            return backdropColors
        }
        switch kernel {
        case .origami:
            return [Color(red: 0.94, green: 0.87, blue: 0.75), Color(red: 0.78, green: 0.55, blue: 0.42), Color(red: 0.36, green: 0.18, blue: 0.16)]
        case .stormSignal:
            return [Color(red: 0.02, green: 0.03, blue: 0.06), Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.35, green: 0.38, blue: 0.48)]
        case .cloudfield, .volumetric:
            return [Color(red: 0.03, green: 0.05, blue: 0.12), Color(red: 0.14, green: 0.22, blue: 0.38), Color(red: 0.50, green: 0.57, blue: 0.76)]
        case .petroleumSheen, .oilfield:
            return [Color(red: 0.01, green: 0.03, blue: 0.04), Color(red: 0.06, green: 0.26, blue: 0.23), Color(red: 0.42, green: 0.18, blue: 0.55)]
        case .inkDiffusion, .suminagashiDrift:
            return [Color(red: 0.04, green: 0.05, blue: 0.09), Color(red: 0.13, green: 0.18, blue: 0.28), Color(red: 0.58, green: 0.44, blue: 0.76)]
        case .retroPlasma:
            return [Color(red: 0.04, green: 0.0, blue: 0.10), Color(red: 0.27, green: 0.05, blue: 0.52), Color(red: 0.0, green: 0.62, blue: 0.76)]
        default:
            return [Color(red: 0.02, green: 0.02, blue: 0.05), accent.opacity(0.65), Color(red: 0.96, green: 0.48, blue: 0.18)]
        }
    }

    private static func dataDrivenPalette(for colorDriver: SwarmColorDriver?, accent: Color) -> [Color]? {
        guard let colorDriver else { return nil }
        let providerColors = colorDriver.providers
            .filter { $0.weight > 0 }
            .prefix(3)
            .map { DesignSystemColors.providerRGBA(for: $0.provider).color.opacity(0.52 + 0.34 * colorDriver.intensityMultiplier) }
        guard !providerColors.isEmpty else { return nil }

        var colors: [Color] = [
            Color(red: 0.02, green: 0.02, blue: 0.05),
            accent.opacity(0.28)
        ]
        colors.append(contentsOf: providerColors)
        if providerColors.count < 3 {
            colors.append(Color(red: 0.96, green: 0.48, blue: 0.18).opacity(0.42))
        }
        return colors
    }

    private static func drawConstellation(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        let count = 90
        for i in 0..<count {
            let a = Double(i) * 2.399963 + time * 0.09
            let r = sqrt(Double(i) / Double(count)) * min(size.width, size.height) * 0.44
            let center = CGPoint(
                x: size.width * 0.5 + cos(a) * r,
                y: size.height * 0.46 + sin(a) * r * 0.72
            )
            let dot = Path(ellipseIn: CGRect(x: center.x - 1.8, y: center.y - 1.8, width: 3.6, height: 3.6))
            context.fill(dot, with: .color(Color.white.opacity(0.18 * opacity)))
        }
    }

    private static func drawFlow(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        for row in 0..<18 {
            var path = Path()
            let y = size.height * (Double(row) + 0.5) / 18.0
            for step in 0...72 {
                let p = Double(step) / 72.0
                let x = p * size.width
                let wave = sin(p * .pi * 4 + Double(row) * 0.55 + time * 0.28)
                let yy = y + wave * 28 + cos(p * .pi * 2 + time * 0.12) * 10
                if step == 0 { path.move(to: CGPoint(x: x, y: yy)) } else { path.addLine(to: CGPoint(x: x, y: yy)) }
            }
            context.stroke(path, with: .color(Color.cyan.opacity(0.12 * opacity)), lineWidth: 1.2)
        }
    }

    private static func drawRibbons(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext, kernel: MobileBackdropKernel) {
        for band in 0..<7 {
            var path = Path()
            let base = size.height * (0.18 + Double(band) * 0.10)
            path.move(to: CGPoint(x: -20, y: base))
            for step in 0...80 {
                let p = Double(step) / 80.0
                let x = p * (size.width + 40) - 20
                let y = base + sin(p * .pi * 2.4 + time * 0.16 + Double(band)) * (32 + Double(band) * 6)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            let color = kernel == .neuralBloom ? Color.purple : (band.isMultiple(of: 2) ? Color.cyan : Color.orange)
            context.stroke(path, with: .color(color.opacity((0.16 + Double(band) * 0.018) * opacity)), lineWidth: CGFloat(18 + band * 4))
        }
    }

    private static func drawOrbs(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext, kernel: MobileBackdropKernel) {
        let colors: [Color] = kernel == .liquidLumen ? [.orange, .purple, .cyan, .pink] : [.cyan, .orange, .purple, .mint]
        for i in 0..<8 {
            let a = Double(i) * 1.7 + time * (0.08 + Double(i % 3) * 0.025)
            let radius = min(size.width, size.height) * CGFloat(0.11 + Double(i % 3) * 0.035)
            let center = CGPoint(
                x: size.width * (0.18 + 0.64 * (0.5 + 0.5 * cos(a * 0.71))),
                y: size.height * (0.16 + 0.68 * (0.5 + 0.5 * sin(a)))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(colors[i % colors.count].opacity(0.18 * opacity))
            )
        }
    }

    private static func drawLattice(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext, kernel: MobileBackdropKernel) {
        let spacing = max(34.0, min(size.width, size.height) / 12.0)
        var path = Path()
        var x = -spacing
        while x < size.width + spacing {
            path.move(to: CGPoint(x: x + sin(time * 0.15) * 12, y: 0))
            path.addLine(to: CGPoint(x: x + size.height * 0.35, y: size.height))
            x += spacing
        }
        var y = -spacing
        while y < size.height + spacing {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y + size.width * 0.18))
            y += spacing
        }
        context.stroke(path, with: .color((kernel == .aetherLattice ? Color.blue : Color.cyan).opacity(0.13 * opacity)), lineWidth: 1)
    }

    private static func drawClouds(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext, kernel: MobileBackdropKernel) {
        for i in 0..<16 {
            let a = Double(i) * 0.83 + time * 0.035
            let w = size.width * CGFloat(0.20 + Double(i % 4) * 0.045)
            let h = w * 0.44
            let center = CGPoint(
                x: size.width * (0.05 + 0.90 * (Double(i % 5) / 4.0)) + cos(a) * 26,
                y: size.height * (0.16 + 0.64 * (Double(i / 5) / 3.0)) + sin(a * 0.8) * 20
            )
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)),
                with: .color(Color.white.opacity((kernel == .volumetric ? 0.10 : 0.14) * opacity))
            )
        }
    }

    private static func drawBloom(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.48)
        for i in 0..<240 {
            let angle = Double(i) * 2.399963 + time * 0.07
            let radius = sqrt(Double(i) / 240.0) * min(size.width, size.height) * 0.45
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let dot = Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
            context.fill(dot, with: .color(Color.orange.opacity(0.20 * opacity)))
        }
    }

    private static func drawCrystal(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        for row in 0..<6 {
            for col in 0..<5 {
                let cx = size.width * (Double(col) + 0.5) / 5.0
                let cy = size.height * (Double(row) + 0.5) / 6.0
                let r = min(size.width, size.height) * (0.08 + 0.01 * sin(time * 0.2 + Double(row + col)))
                var path = Path()
                for side in 0..<6 {
                    let a = Double(side) * .pi / 3 + time * 0.02
                    let p = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
                    if side == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(Color.mint.opacity(0.16 * opacity)), lineWidth: 1.4)
            }
        }
    }

    private static func drawMycelium(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        for i in 0..<36 {
            var path = Path()
            let start = CGPoint(x: size.width * Double(i % 9) / 8.0, y: size.height * Double(i / 9) / 4.0)
            path.move(to: start)
            for step in 1...18 {
                let p = Double(step) / 18.0
                let x = start.x + cos(Double(i) + p * 4 + time * 0.10) * p * 150
                let y = start.y + sin(Double(i) * 1.7 + p * 5) * p * 110
                path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(Color.green.opacity(0.12 * opacity)), lineWidth: 1.5)
        }
    }

    private static func drawMarble(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext, kernel: MobileBackdropKernel) {
        let colors: [Color] = kernel == .petroleumSheen ? [.cyan, .purple, .green, .orange] : [.blue, .purple, .orange, .white]
        for i in 0..<18 {
            var path = Path()
            let y0 = size.height * Double(i) / 17.0
            for step in 0...80 {
                let p = Double(step) / 80.0
                let x = p * size.width
                let y = y0 + sin(p * 10 + Double(i) * 0.6 + time * 0.1) * 26 + sin(p * 22 + time * 0.06) * 10
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(colors[i % colors.count].opacity(0.10 * opacity)), lineWidth: 9)
        }
    }

    private static func drawBeam(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        let sweep = sin(time * 0.18) * size.width * 0.20
        var cone = Path()
        cone.move(to: CGPoint(x: size.width * 0.5 + sweep, y: size.height * 0.92))
        cone.addLine(to: CGPoint(x: size.width * 0.15, y: size.height * 0.08))
        cone.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.05))
        cone.closeSubpath()
        context.fill(cone, with: .color(Color.white.opacity(0.16 * opacity)))
        context.stroke(cone, with: .color(Color.blue.opacity(0.20 * opacity)), lineWidth: 2)
    }

    private static func drawStorm(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        drawClouds(time: time, opacity: opacity * 0.8, size: size, context: &context, kernel: .stormSignal)
        for i in 0..<3 {
            var bolt = Path()
            let x = size.width * (0.25 + Double(i) * 0.24) + sin(time + Double(i)) * 20
            bolt.move(to: CGPoint(x: x, y: size.height * 0.18))
            for step in 1...6 {
                bolt.addLine(to: CGPoint(x: x + CGFloat((step % 2 == 0 ? -1 : 1) * 24), y: size.height * (0.18 + Double(step) * 0.08)))
            }
            context.stroke(bolt, with: .color(Color.white.opacity(0.16 * opacity)), lineWidth: 2)
        }
    }

    private static func drawPlasma(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        let rows = 18
        let cols = 12
        for row in 0..<rows {
            for col in 0..<cols {
                let value = sin(Double(row) * 0.8 + time * 0.3) + cos(Double(col) * 0.9 + time * 0.22)
                let hue = 0.58 + value * 0.08
                let color = Color(hue: hue, saturation: 0.82, brightness: 0.9).opacity(0.09 * opacity)
                let rect = CGRect(
                    x: size.width * Double(col) / Double(cols),
                    y: size.height * Double(row) / Double(rows),
                    width: size.width / Double(cols) + 1,
                    height: size.height / Double(rows) + 1
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private static func drawPaper(time: TimeInterval, opacity: Double, size: CGSize, context: inout GraphicsContext) {
        for i in 0..<80 {
            var path = Path()
            let y = size.height * Double(i) / 80.0 + sin(Double(i) + time * 0.03) * 2
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y + sin(Double(i) * 0.4) * 6))
            context.stroke(path, with: .color(Color.brown.opacity(0.05 * opacity)), lineWidth: 0.6)
        }
    }
}

private extension MobileBackdropKernel {
    var readabilityScrim: Double {
        switch self {
        case .origami: return 0.18
        case .constellation, .vogelBloom, .myceliumMesh: return 0.28
        case .retroPlasma, .moire, .liquidLumen: return 0.46
        default: return 0.36
        }
    }
}

private extension CGFloat {
    static func + (lhs: CGFloat, rhs: Double) -> CGFloat { lhs + CGFloat(rhs) }
    static func - (lhs: CGFloat, rhs: Double) -> CGFloat { lhs - CGFloat(rhs) }
    static func * (lhs: CGFloat, rhs: Double) -> CGFloat { lhs * CGFloat(rhs) }
    static func * (lhs: Double, rhs: CGFloat) -> CGFloat { CGFloat(lhs) * rhs }
    static func / (lhs: CGFloat, rhs: Double) -> CGFloat { lhs / CGFloat(rhs) }
}
