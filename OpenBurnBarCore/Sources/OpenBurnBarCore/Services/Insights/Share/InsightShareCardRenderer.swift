import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Renders shareable cards from any verdict, bullet, or widget.
///
/// Plan §5.4 — every insight is exportable as:
///   • 1080×1350 PNG (Instagram-friendly portrait)
///   • 1080×1080 PNG (square)
///   • A4 PDF (for weekly/monthly/annual recaps)
///   • 9:16 MP4 (for Year-in-Coding)
///
/// The renderer is platform-agnostic for layout computation; the
/// actual bitmap generation uses the host platform's graphics APIs.
public struct InsightShareCardRenderer: Sendable {

    public enum CardFormat: Sendable {
        case portrait1080x1350
        case square1080x1080
        case a4PDF
        case video9x16
    }

    public struct CardLayout: Sendable {
        public let width: CGFloat
        public let height: CGFloat
        public let backgroundColor: PlatformColor
        public let textColor: PlatformColor
        public let accentColor: PlatformColor
        public let margin: CGFloat
        public let headlineFontSize: CGFloat
        public let bodyFontSize: CGFloat
        public let footerFontSize: CGFloat

        public init(
            width: CGFloat,
            height: CGFloat,
            backgroundColor: PlatformColor,
            textColor: PlatformColor,
            accentColor: PlatformColor,
            margin: CGFloat = 48,
            headlineFontSize: CGFloat = 48,
            bodyFontSize: CGFloat = 28,
            footerFontSize: CGFloat = 20
        ) {
            self.width = width
            self.height = height
            self.backgroundColor = backgroundColor
            self.textColor = textColor
            self.accentColor = accentColor
            self.margin = margin
            self.headlineFontSize = headlineFontSize
            self.bodyFontSize = bodyFontSize
            self.footerFontSize = footerFontSize
        }
    }

    public init() {}

    /// Layout constants for each format.
    public func layout(for format: CardFormat, isDark: Bool = true) -> CardLayout {
        switch format {
        case .portrait1080x1350:
            return CardLayout(
                width: 1080,
                height: 1350,
                backgroundColor: isDark ? .init(r: 14, g: 13, b: 11) : .init(r: 237, g: 240, b: 229),
                textColor: isDark ? .init(r: 240, g: 235, b: 226) : .init(r: 28, g: 32, b: 20),
                accentColor: .init(r: 232, g: 112, b: 96)
            )
        case .square1080x1080:
            return CardLayout(
                width: 1080,
                height: 1080,
                backgroundColor: isDark ? .init(r: 14, g: 13, b: 11) : .init(r: 237, g: 240, b: 229),
                textColor: isDark ? .init(r: 240, g: 235, b: 226) : .init(r: 28, g: 32, b: 20),
                accentColor: .init(r: 232, g: 112, b: 96)
            )
        case .a4PDF:
            // A4 at 150 DPI
            return CardLayout(
                width: 1240,
                height: 1754,
                backgroundColor: .init(r: 255, g: 255, b: 255),
                textColor: .init(r: 28, g: 32, b: 20),
                accentColor: .init(r: 232, g: 112, b: 96),
                margin: 80,
                headlineFontSize: 42,
                bodyFontSize: 24,
                footerFontSize: 18
            )
        case .video9x16:
            // 1080×1920 at 30fps placeholder
            return CardLayout(
                width: 1080,
                height: 1920,
                backgroundColor: isDark ? .init(r: 14, g: 13, b: 11) : .init(r: 237, g: 240, b: 229),
                textColor: isDark ? .init(r: 240, g: 235, b: 226) : .init(r: 28, g: 32, b: 20),
                accentColor: .init(r: 232, g: 112, b: 96)
            )
        }
    }
}

// MARK: - Platform color abstraction

public struct PlatformColor: Sendable {
    public let r: CGFloat
    public let g: CGFloat
    public let b: CGFloat
    public let a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) {
        self.r = r / 255.0
        self.g = g / 255.0
        self.b = b / 255.0
        self.a = a
    }

    #if canImport(UIKit)
    public var uiColor: UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }
    #endif

    #if canImport(AppKit)
    public var nsColor: NSColor {
        NSColor(red: r, green: g, blue: b, alpha: a)
    }
    #endif
}
