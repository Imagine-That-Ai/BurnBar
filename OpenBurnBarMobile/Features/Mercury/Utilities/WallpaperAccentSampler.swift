import Foundation
import SwiftUI
import CoreGraphics
import ImageIO

/// Samples the dominant accent color from a Mac wallpaper payload.
///
/// The input is a base64-encoded JPEG/PNG (the same field that
/// `MercuryPeer.blurredWallpaperBase64` carries — already blurred and
/// downscaled by the Mac side, typically <50KB). ImageIO first decodes a
/// bounded thumbnail without caching the full image, then Core Graphics
/// renders it into a small deterministic RGBA buffer. Finally, we average
/// the visible pixels and bump saturation a bit so the resulting color
/// reads as an accent rather than a muddy backdrop.
///
/// Why not k-means or histogram quantization? The wallpaper is already
/// blurred to one dominant tone — average is cheap, deterministic, and
/// good enough. We trade a tiny amount of fidelity for fast, predictable
/// results that play well with the personalization cache.
enum WallpaperAccentSampler {
    private static let maximumEncodedImageBytes = 512 * 1_024
    private static let maximumBase64Characters =
        ((maximumEncodedImageBytes + 2) / 3) * 4
    private static let maximumSampleDimension = 64

    /// Returns a SwiftUI `Color` for the given base64 payload, or `nil`
    /// when the payload is empty/invalid. Callers should fall back to
    /// `MercuryAccent.blue.staticColor` in the nil case.
    @MainActor
    static func dominantAccent(fromBase64 base64: String?) -> Color? {
        guard let base64,
              !base64.isEmpty,
              base64.utf8.count <= maximumBase64Characters,
              let data = Data(base64Encoded: base64),
              data.count <= maximumEncodedImageBytes else {
            return nil
        }
        return dominantAccent(fromImageData: data)
    }

    @MainActor
    static func dominantAccent(fromImageData data: Data) -> Color? {
        guard !data.isEmpty,
              data.count <= maximumEncodedImageBytes,
              let image = downsampledImage(from: data),
              let average = averageRGB(from: image) else {
            return nil
        }
        return punchUp(r: average.r, g: average.g, b: average.b)
    }

    private static func downsampledImage(from data: Data) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSampleDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        )
    }

    private static func averageRGB(from image: CGImage) -> (r: Double, g: Double, b: Double)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bitmap = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let didRender = bitmap.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard didRender else { return nil }

        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var alphaTotal = 0.0
        for pixelOffset in stride(from: 0, to: bitmap.count, by: bytesPerPixel) {
            let alpha = Double(bitmap[pixelOffset + 3]) / 255.0
            guard alpha > 0 else { continue }
            redTotal += Double(bitmap[pixelOffset])
            greenTotal += Double(bitmap[pixelOffset + 1])
            blueTotal += Double(bitmap[pixelOffset + 2])
            alphaTotal += alpha
        }
        guard alphaTotal > 0 else { return nil }

        return (
            r: min(redTotal / alphaTotal / 255.0, 1.0),
            g: min(greenTotal / alphaTotal / 255.0, 1.0),
            b: min(blueTotal / alphaTotal / 255.0, 1.0)
        )
    }

    /// Push the sampled tone toward a presentable accent: clamp luminance
    /// into a legible band and lift saturation enough that the color
    /// reads as an accent against the dark glass background.
    private static func punchUp(r: Double, g: Double, b: Double) -> Color {
        // RGB → HSV.
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        var hue: Double = 0
        if delta > 0.0001 {
            if maxV == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = ((b - r) / delta) + 2
            } else {
                hue = ((r - g) / delta) + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        var saturation = maxV == 0 ? 0 : delta / maxV
        var brightness = maxV

        // Lift saturation if the wallpaper is desaturated (e.g. greyscale).
        saturation = max(saturation, 0.55)
        // Keep brightness in a legible band against dark glass.
        brightness = min(max(brightness, 0.72), 0.92)

        // HSV → RGB.
        let c = brightness * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        var rr = 0.0, gg = 0.0, bb = 0.0
        switch hue * 6 {
        case 0..<1: rr = c; gg = x; bb = 0
        case 1..<2: rr = x; gg = c; bb = 0
        case 2..<3: rr = 0; gg = c; bb = x
        case 3..<4: rr = 0; gg = x; bb = c
        case 4..<5: rr = x; gg = 0; bb = c
        default:    rr = c; gg = 0; bb = x
        }
        return Color(red: rr + m, green: gg + m, blue: bb + m)
    }
}
