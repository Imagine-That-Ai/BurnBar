import Foundation
import SwiftUI
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

/// Samples the dominant accent color from a Mac wallpaper payload.
///
/// The input is a base64-encoded JPEG/PNG (the same field that
/// `MercuryPeer.blurredWallpaperBase64` carries — already blurred and
/// downscaled by the Mac side, typically <50KB). We use Core Image's
/// `CIAreaAverage` filter to compute a single-pixel average, then bump
/// saturation a bit so the resulting color reads as an accent rather
/// than a muddy backdrop.
///
/// Why not k-means or histogram quantization? The wallpaper is already
/// blurred to one dominant tone — average is cheap, deterministic, and
/// good enough. We trade a tiny amount of fidelity for fast, predictable
/// results that play well with the personalization cache.
enum WallpaperAccentSampler {
    /// Returns a SwiftUI `Color` for the given base64 payload, or `nil`
    /// when the payload is empty/invalid. Callers should fall back to
    /// `MercuryAccent.blue.staticColor` in the nil case.
    @MainActor
    static func dominantAccent(fromBase64 base64: String?) -> Color? {
        guard let base64,
              !base64.isEmpty,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return dominantAccent(fromImageData: data)
    }

    @MainActor
    static func dominantAccent(fromImageData data: Data) -> Color? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data),
              let cgImage = image.cgImage else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        return dominantAccent(from: ciImage)
        #else
        return nil
        #endif
    }

    /// Internal seam — public for testing.
    @MainActor
    static func dominantAccent(from ciImage: CIImage) -> Color? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let extentVector = CIVector(
            x: extent.origin.x,
            y: extent.origin.y,
            z: extent.size.width,
            w: extent.size.height
        )
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: extentVector]
        ),
        let outputImage = filter.outputImage else {
            return nil
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        return punchUp(r: r, g: g, b: b)
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
