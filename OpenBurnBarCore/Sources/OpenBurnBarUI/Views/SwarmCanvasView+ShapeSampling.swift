import SwiftUI
import Foundation
import CoreGraphics
import CoreText
import OpenBurnBarKernel
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Text/logo/emoji point sampling + image foreground extraction.
// Extracted from SwarmCanvasView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension SwarmSimulation {

    struct ShapePoint {
        let point: CGPoint
        let role: String?
        let logoColor: RGBA?
        let progress: Double

        init(point: CGPoint, role: String?, progress: Double, logoColor: RGBA? = nil) {
            self.point = point
            self.role = role
            self.progress = progress
            self.logoColor = logoColor
        }
    }
    static func sampleTextPoints(text: String, fontSize: CGFloat) -> [CGPoint] {
        let side = 400
        let bytesPerRow = side
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attrStr = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 1, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(
            x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(side) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return [] }
        let buffer = data.assumingMemoryBound(to: UInt8.self)

        var pts: [CGPoint] = []
        let gap = 6
        for y in stride(from: 0, to: side, by: gap) {
            for x in stride(from: 0, to: side, by: gap) where buffer[y * bytesPerRow + x] > 128 {
                pts.append(CGPoint(
                    x: CGFloat(x - side / 2) / CGFloat(side / 2),
                    y: -CGFloat(y - side / 2) / CGFloat(side / 2)   // flip Y to match top-left origin
                ))
            }
        }
        return pts
    }

    static func logoPoints(for provider: AgentProvider, fallback: [ShapePoint]) -> [ShapePoint] {
        if provider == .factory {
            return generateFactoryLogoPoints()
        }
        if provider == .hermes {
            return generateHermesLogoPoints()
        }

        let candidates: [String]
        switch provider {
        case .openAI:
            candidates = [provider.bundledLogoName, "OpenAILogo"]
        case .claudeCode:
            candidates = [provider.bundledLogoName, "ClaudeCodeLogo", "AnthropicLogo"]
        case .geminiCLI:
            candidates = [provider.bundledLogoName, "GeminiCLILogo"]
        case .antigravity:
            candidates = ["AntigravityLogo"]
        case .xAI:
            candidates = ["GrokLogo", "xAILogo"]
        default:
            candidates = [provider.bundledLogoName]
        }
        return logoPoints(named: candidates, fallback: fallback)
    }

    static func logoPoints(named candidates: [String], fallback: [ShapePoint]) -> [ShapePoint] {
        for candidate in candidates {
            if let image = platformImage(named: candidate) {
                let points = sampleLogoImage(image, maxPoints: 1600)
                if !points.isEmpty {
                    return points
                }
            }
        }
        return fallback
    }

    static func sampleLogoImage(_ image: CGImage, maxPoints: Int) -> [ShapePoint] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return [] }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let backgroundColor = inferredOpaqueBackgroundColor(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel
        )
        let borderBackgroundMask = connectedBackgroundMask(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            backgroundColor: backgroundColor
        )

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let pixelIndex = y * width + x
                if isLogoForegroundPixel(
                    pixels,
                    offset: offset,
                    pixelIndex: pixelIndex,
                    borderBackgroundMask: borderBackgroundMask,
                    backgroundColor: backgroundColor
                ) {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { return [] }

        let occupiedWidth = max(1, maxX - minX + 1)
        let occupiedHeight = max(1, maxY - minY + 1)
        let sampleStep = max(2, Int(ceil(sqrt(Double(occupiedWidth * occupiedHeight) / Double(maxPoints)))))
        let centerX = Double(minX + maxX) / 2.0
        let centerY = Double(minY + maxY) / 2.0
        let scale = Double(max(occupiedWidth, occupiedHeight)) / 2.0

        var points: [ShapePoint] = []
        points.reserveCapacity(maxPoints)
        for y in stride(from: minY, through: maxY, by: sampleStep) {
            for x in stride(from: minX, through: maxX, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let pixelIndex = y * width + x
                guard isLogoForegroundPixel(
                    pixels,
                    offset: offset,
                    pixelIndex: pixelIndex,
                    borderBackgroundMask: borderBackgroundMask,
                    backgroundColor: backgroundColor
                ) else { continue }

                let alpha = Double(pixels[offset + 3]) / 255.0
                let premultipliedRed = Double(pixels[offset]) / 255.0
                let premultipliedGreen = Double(pixels[offset + 1]) / 255.0
                let premultipliedBlue = Double(pixels[offset + 2]) / 255.0
                let red = alpha > 0 ? min(1.0, premultipliedRed / alpha) : 0
                let green = alpha > 0 ? min(1.0, premultipliedGreen / alpha) : 0
                let blue = alpha > 0 ? min(1.0, premultipliedBlue / alpha) : 0
                let color = RGBA(r: red, g: green, b: blue, a: alpha)
                let luminance = relativeLuminance(color)
                let role: String
                if luminance < 0.30 {
                    role = "logo-flame-outer"
                } else if luminance > 0.76 {
                    role = "logo-flame-spark"
                } else {
                    role = "logo-flame-inner"
                }
                points.append(
                    ShapePoint(
                        point: CGPoint(
                            x: (Double(x) - centerX) / scale,
                            y: (Double(y) - centerY) / scale
                        ),
                        role: role,
                        progress: Double(points.count % max(maxPoints, 1)) / Double(max(maxPoints - 1, 1)),
                        logoColor: color
                    )
                )
            }
        }

        guard points.count > maxPoints else { return points }
        return evenlyDownsample(points, maxCount: maxPoints)
    }

    static func inferredOpaqueBackgroundColor(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> RGBA? {
        let cornerSide = min(8, max(1, min(width, height) / 10))
        let cornerRanges: [(ClosedRange<Int>, ClosedRange<Int>)] = [
            (0...max(0, cornerSide - 1), 0...max(0, cornerSide - 1)),
            (max(0, width - cornerSide)...max(0, width - 1), 0...max(0, cornerSide - 1)),
            (0...max(0, cornerSide - 1), max(0, height - cornerSide)...max(0, height - 1)),
            (max(0, width - cornerSide)...max(0, width - 1), max(0, height - cornerSide)...max(0, height - 1))
        ]

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var alpha = 0.0
        var count = 0.0
        for (xRange, yRange) in cornerRanges {
            for y in yRange {
                for x in xRange {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    let a = Double(pixels[offset + 3]) / 255.0
                    guard a > 0.85 else { continue }
                    alpha += a
                    red += Double(pixels[offset]) / 255.0
                    green += Double(pixels[offset + 1]) / 255.0
                    blue += Double(pixels[offset + 2]) / 255.0
                    count += 1
                }
            }
        }

        guard count >= 4, alpha / count > 0.88 else { return nil }
        return RGBA(r: red / count, g: green / count, b: blue / count, a: alpha / count)
    }

    static func connectedBackgroundMask(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        backgroundColor: RGBA?
    ) -> [Bool]? {
        guard let backgroundColor else { return nil }
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [(x: Int, y: Int)] = []
        queue.reserveCapacity(width * 2 + height * 2)

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let index = y * width + x
            guard !visited[index] else { return }
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard isBackgroundLikePixel(pixels, offset: offset, backgroundColor: backgroundColor) else { return }
            visited[index] = true
            queue.append((x, y))
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            enqueue(current.x + 1, current.y)
            enqueue(current.x - 1, current.y)
            enqueue(current.x, current.y + 1)
            enqueue(current.x, current.y - 1)
        }
        return visited
    }

    static func isBackgroundLikePixel(
        _ pixels: [UInt8],
        offset: Int,
        backgroundColor: RGBA
    ) -> Bool {
        let alpha = Double(pixels[offset + 3]) / 255.0
        guard alpha > 0.22 else { return true }
        let red = alpha > 0 ? min(1.0, Double(pixels[offset]) / 255.0 / alpha) : 0
        let green = alpha > 0 ? min(1.0, Double(pixels[offset + 1]) / 255.0 / alpha) : 0
        let blue = alpha > 0 ? min(1.0, Double(pixels[offset + 2]) / 255.0 / alpha) : 0
        let distance = sqrt(
            pow(red - backgroundColor.r, 2) +
            pow(green - backgroundColor.g, 2) +
            pow(blue - backgroundColor.b, 2)
        )
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let saturation = maxChannel - minChannel
        return distance < 0.12 || (relativeLuminance(backgroundColor) > 0.86 && luminance > 0.88 && saturation < 0.10)
    }

    static func isLogoForegroundPixel(
        _ pixels: [UInt8],
        offset: Int,
        pixelIndex: Int,
        borderBackgroundMask: [Bool]?,
        backgroundColor: RGBA?
    ) -> Bool {
        let alpha = Double(pixels[offset + 3]) / 255.0
        guard alpha > 0.22 else { return false }
        if let borderBackgroundMask, borderBackgroundMask.indices.contains(pixelIndex) {
            return !borderBackgroundMask[pixelIndex]
        }
        let premultipliedRed = Double(pixels[offset]) / 255.0
        let premultipliedGreen = Double(pixels[offset + 1]) / 255.0
        let premultipliedBlue = Double(pixels[offset + 2]) / 255.0
        let red = alpha > 0 ? min(1.0, premultipliedRed / alpha) : 0
        let green = alpha > 0 ? min(1.0, premultipliedGreen / alpha) : 0
        let blue = alpha > 0 ? min(1.0, premultipliedBlue / alpha) : 0

        guard let backgroundColor else { return true }
        let distance = sqrt(
            pow(red - backgroundColor.r, 2) +
            pow(green - backgroundColor.g, 2) +
            pow(blue - backgroundColor.b, 2)
        )
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let saturation = maxChannel - minChannel

        if distance < 0.09 { return false }
        if relativeLuminance(backgroundColor) > 0.86, luminance > 0.88, saturation < 0.10 {
            return false
        }
        return true
    }

    static func fallbackLogoPoints(for provider: AgentProvider) -> [ShapePoint] {
        switch provider {
        case .factory:
            return generateFactoryLogoPoints()
        case .openAI:
            return generateOpenAILogoPoints()
        case .codex:
            return generateCodexLogoPoints()
        case .claudeCode:
            return generateAnthropicLogoPoints()
        case .geminiCLI:
            return generateGeminiLogoPoints()
        case .antigravity:
            return generateAntigravityLogoPoints()
        case .cursor:
            return generateCursorLogoPoints()
        case .openCode:
            return generateOpenCodeLogoPoints()
        case .xAI:
            return generateXAILogoPoints()
        case .ollama:
            return generateOllamaLogoPoints()
        case .hermes:
            return generateHermesLogoPoints()
        default:
            return initialsLogoPoints(for: provider)
        }
    }

    static func initialsLogoPoints(for provider: AgentProvider) -> [ShapePoint] {
        let words = provider.rawValue
            .split(separator: " ")
            .map(String.init)
        let initials: String
        if words.count >= 2 {
            initials = words.prefix(2).compactMap(\.first).map(String.init).joined()
        } else {
            initials = String(provider.rawValue.prefix(2))
        }
        let points = sampleTextPoints(text: initials.uppercased(), fontSize: 220)
        let denominator = max(1, points.count - 1)
        return points.enumerated().map { index, point in
            ShapePoint(
                point: point,
                role: index.isMultiple(of: 3) ? "logo-flame-spark" : "logo-flame-inner",
                progress: Double(index) / Double(denominator)
            )
        }
    }

    static func evenlyDownsample(_ points: [ShapePoint], maxCount: Int) -> [ShapePoint] {
        guard maxCount > 0, points.count > maxCount else { return points }
        return (0..<maxCount).map { index in
            let t = Double(index) / Double(max(maxCount - 1, 1))
            return points[min(points.count - 1, Int((Double(points.count - 1) * t).rounded()))]
        }
    }

    static func platformImage(named name: String) -> CGImage? {
        #if canImport(AppKit)
        var nsImage: NSImage?
        if let img = NSImage(named: NSImage.Name(name)) {
            nsImage = img
        } else {
            for bundle in Bundle.allBundles {
                if let img = bundle.image(forResource: NSImage.Name(name)) {
                    nsImage = img
                    break
                }
            }
        }

        guard let image = nsImage else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return cgImage
        }

        // Fallback: draw NSImage into a bitmap context to extract CGImage robustly
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
        #endif

        #if canImport(UIKit)
        var uiImage: UIImage?
        if let img = UIImage(named: name) {
            uiImage = img
        } else {
            for bundle in Bundle.allBundles {
                if let img = UIImage(named: name, in: bundle, compatibleWith: nil) {
                    uiImage = img
                    break
                }
            }
        }
        return uiImage?.cgImage
        #endif
    }

    static func providerTextPoints(for provider: AgentProvider) -> [ShapePoint] {
        guard let data = providerTextPointsData[provider] else { return [] }
        var raw: [(point: CGPoint, role: String)] = []
        raw.reserveCapacity(data.count / 2)
        var idx = 0
        while idx < data.count {
            raw.append((CGPoint(x: data[idx], y: data[idx+1]), "logo-flame-inner"))
            idx += 2
        }
        var pts: [ShapePoint] = []
        pts.reserveCapacity(raw.count)
        let denom = Double(max(raw.count - 1, 1))
        for (i, item) in raw.enumerated() {
            pts.append(ShapePoint(point: item.point, role: item.role, progress: Double(i) / denom))
        }
        return pts
    }

    static func sampleEmojiPoints(emoji: String, fontSize: CGFloat) -> [ShapePoint] {
        let side = 320
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)

        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, fontSize, nil)
        let attrStr = NSAttributedString(
            string: emoji,
            attributes: [
                .font: font
            ]
        )
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        ctx.textPosition = CGPoint(
            x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(side) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, ctx)

        var pts: [ShapePoint] = []
        let gap = 5 // Premium particle density spacing
        for y in stride(from: 0, to: side, by: gap) {
            for x in stride(from: 0, to: side, by: gap) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = pixels[offset + 3]
                if alpha > 40 {
                    let red = pixels[offset]
                    let green = pixels[offset + 1]
                    let blue = pixels[offset + 2]

                    let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
                    let role: String
                    if luminance < 80 {
                        role = "logo-flame-outer"
                    } else if luminance > 210 {
                        role = "logo-flame-spark"
                    } else {
                        role = "logo-flame-inner"
                    }

                    // Center and scale to fit standard -0.35 to 0.35 layout box nicely
                    pts.append(ShapePoint(
                        point: CGPoint(
                            x: (CGFloat(x - side / 2) / CGFloat(side / 2)) * 0.75,
                            y: (-CGFloat(y - side / 2) / CGFloat(side / 2)) * 0.75
                        ),
                        role: role,
                        progress: Double(pts.count)
                    ))
                }
            }
        }

        // Normalize progress stably
        if !pts.isEmpty {
            let denom = Double(pts.count - 1)
            for i in pts.indices {
                pts[i] = ShapePoint(
                    point: pts[i].point,
                    role: pts[i].role,
                    progress: denom > 0 ? Double(i) / denom : 0.0
                )
            }
        }

        return pts
    }
}
