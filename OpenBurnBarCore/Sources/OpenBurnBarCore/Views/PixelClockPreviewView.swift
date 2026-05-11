import Foundation
import SwiftUI

// MARK: - Pixel Clock Preview View
//
// A faithful 8×32 LED-matrix preview that mirrors what the ULANZI TC001
// renders when AWTRIX HTTP is reachable. The view is intentionally
// fixed-aspect (32:8) so settings cards never re-flow when the user
// flips palette / layout / provider filter.
//
// The preview is purely a visual mock backed by `PixelClockFramePresenter`
// — it does not call the AWTRIX HTTP API. Networking is owned by the
// daemon-side `PixelClockController`.

public struct PixelClockPreviewView: View {
    public let frame: PixelClockPreviewFrame
    public let cornerRadius: CGFloat
    public let glow: Bool

    public init(
        frame: PixelClockPreviewFrame,
        cornerRadius: CGFloat = UnifiedDesignSystem.Radius.md,
        glow: Bool = true
    ) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.glow = glow
    }

    public var body: some View {
        GeometryReader { proxy in
            let cellWidth = proxy.size.width / CGFloat(PixelClockPreviewFrame.columns)
            let cellHeight = proxy.size.height / CGFloat(PixelClockPreviewFrame.rows)
            let cellSize = min(cellWidth, cellHeight)
            let dotSize = max(cellSize * 0.78, 1)

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)

                Canvas { context, size in
                    let xPad = (size.width - cellWidth * CGFloat(PixelClockPreviewFrame.columns)) / 2
                    let yPad = (size.height - cellHeight * CGFloat(PixelClockPreviewFrame.rows)) / 2
                    for row in 0..<PixelClockPreviewFrame.rows {
                        for column in 0..<PixelClockPreviewFrame.columns {
                            let pixel = frame.pixel(row: row, column: column)
                            let cx = xPad + (CGFloat(column) + 0.5) * cellWidth
                            let cy = yPad + (CGFloat(row) + 0.5) * cellHeight
                            let rect = CGRect(
                                x: cx - dotSize / 2,
                                y: cy - dotSize / 2,
                                width: dotSize,
                                height: dotSize
                            )
                            let dotColor = pixel.color
                            if pixel.isLit {
                                if glow {
                                    var glowContext = context
                                    glowContext.addFilter(.blur(radius: dotSize * 0.45))
                                    glowContext.fill(
                                        Path(ellipseIn: rect.insetBy(dx: -dotSize * 0.18, dy: -dotSize * 0.18)),
                                        with: .color(dotColor.opacity(0.55))
                                    )
                                }
                                context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                            } else {
                                context.fill(
                                    Path(ellipseIn: rect),
                                    with: .color(Color.white.opacity(0.035))
                                )
                            }
                        }
                    }
                }
            }
        }
        .aspectRatio(
            CGFloat(PixelClockPreviewFrame.columns) / CGFloat(PixelClockPreviewFrame.rows),
            contentMode: .fit
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.accessibilityLabel)
    }
}

// MARK: - Pixel Clock Preview Frame

public struct PixelClockPreviewFrame: Equatable, Sendable {
    public static let columns = 32
    public static let rows = 8

    public struct Pixel: Equatable, Sendable {
        public let isLit: Bool
        public let color: Color

        public init(isLit: Bool, color: Color) {
            self.isLit = isLit
            self.color = color
        }

        public static let off = Pixel(isLit: false, color: .clear)
    }

    public let id: Int
    public let pixels: [[Pixel]]
    public let accessibilityLabel: String

    public init(id: Int, pixels: [[Pixel]], accessibilityLabel: String) {
        self.id = id
        self.pixels = pixels
        self.accessibilityLabel = accessibilityLabel
    }

    public func pixel(row: Int, column: Int) -> Pixel {
        guard row >= 0, row < pixels.count, column >= 0, column < pixels[row].count else {
            return .off
        }
        return pixels[row][column]
    }

    public static let blank = PixelClockPreviewFrame(
        id: 0,
        pixels: Array(
            repeating: Array(repeating: Pixel.off, count: columns),
            count: rows
        ),
        accessibilityLabel: "Pixel clock preview, off"
    )
}

// MARK: - Frame Presenter

/// Pure-Swift mapper from settings to LED frames. Lives in core so iOS
/// and macOS can share the visualization without re-implementing it.
public enum PixelClockFramePresenter {

    /// Build the preview frame the settings card shows.
    /// - Parameters:
    ///   - config: Current pixel clock config.
    ///   - tick: Animation tick (caller can pass a monotonically increasing int to advance the carousel).
    public static func makePreviewFrame(
        config: PixelClockConfig,
        tick: Int = 0
    ) -> PixelClockPreviewFrame {
        let items = mockItems(for: config)
        let primary = Color(hex: config.palette.primaryHex)
        let secondary = Color(hex: config.palette.secondaryHex)

        switch config.layout {
        case .providerDashboard:
            return providerDashboardFrame(
                items: items,
                config: config,
                primary: primary,
                secondary: secondary,
                tick: tick
            )
        case .quotaCarousel:
            return quotaCarouselFrame(
                items: items,
                config: config,
                primary: primary,
                secondary: secondary,
                tick: tick
            )
        case .burnStatus:
            return burnStatusFrame(
                items: items,
                config: config,
                primary: primary,
                secondary: secondary
            )
        case .alertsOnly:
            return alertsOnlyFrame(
                items: items,
                config: config,
                primary: primary,
                secondary: secondary
            )
        }
    }

    // MARK: - Layouts

    private static func providerDashboardFrame(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        primary: Color,
        secondary: Color,
        tick: Int
    ) -> PixelClockPreviewFrame {
        var pixels = blankPixelGrid()
        let item = items.indices.isEmpty
            ? PixelClockQuotaItem(
                providerID: "openburnbar",
                providerName: "OpenBurnBar",
                percentUsed: 0,
                usageText: "waiting",
                windowLabel: ""
            )
            : items[abs(tick) % items.count]
        let remaining = remainingPercent(for: item)
        let quotaColor = Color(hex: config.palette.hexColor(for: item.percentUsed))

        paintProviderLogo(for: item, into: &pixels)

        if tick.isMultiple(of: 2) {
            paintSpinner(config.workingSpinnerStyle, into: &pixels, originColumn: 10, originRow: 1, config: config, tick: tick)
        }

        let window = normalizedWindowLabel(item.windowLabel)
        if !window.isEmpty {
            for (idx, char) in Array(window).enumerated() {
                paintGlyph(
                    char,
                    into: &pixels,
                    originColumn: max(20, 32 - window.count * 4) + idx * 4,
                    originRow: 1,
                    color: quotaColor
                )
            }
        }

        let filled = max(min(Int(round(Double(remaining) / 100.0 * 19.0)), 19), 0)
        for column in 0..<filled {
            pixels[7][column + 12] = PixelClockPreviewFrame.Pixel(
                isLit: true,
                color: quotaColor
            )
        }

        return PixelClockPreviewFrame(
            id: identity(config: config, tick: tick, layout: .providerDashboard),
            pixels: pixels,
            accessibilityLabel: previewAccessibilityLabel(config: config, item: item)
        )
    }

    private static func quotaCarouselFrame(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        primary: Color,
        secondary: Color,
        tick: Int
    ) -> PixelClockPreviewFrame {
        var pixels = blankPixelGrid()
        let item = items.indices.isEmpty
            ? PixelClockQuotaItem(
                providerID: "openburnbar",
                providerName: "WAIT",
                percentUsed: 0,
                usageText: "0%",
                windowLabel: ""
            )
            : items[abs(tick) % items.count]

        paintProviderLogo(
            for: item,
            into: &pixels
        )

        // Top-right percentage bar.
        let barWidth = 21
        let remaining = remainingPercent(for: item)
        let barColumns = max(min(Int(round(Double(remaining) / 100.0 * Double(barWidth))), barWidth), 0)
        for column in 0..<barColumns {
            let color = item.percentUsed >= 85
                ? Color(hex: PixelClockPalette.emberWhimsy.primaryHex)
                : primary
            pixels[1][column + 10] = PixelClockPreviewFrame.Pixel(
                isLit: true,
                color: color.opacity(0.9)
            )
        }

        // Bottom-right: remaining percent digits.
        let percent = max(min(remaining, 99), 0)
        let firstDigit = Character(String(percent / 10))
        let secondDigit = Character(String(percent % 10))
        paintGlyph(firstDigit, into: &pixels, originColumn: 17, originRow: 3, color: primary)
        paintGlyph(secondDigit, into: &pixels, originColumn: 21, originRow: 3, color: primary)
        paintGlyph("%", into: &pixels, originColumn: 25, originRow: 3, color: secondary)

        return PixelClockPreviewFrame(
            id: identity(config: config, tick: tick, layout: .quotaCarousel),
            pixels: pixels,
            accessibilityLabel: previewAccessibilityLabel(config: config, item: item)
        )
    }

    private static func burnStatusFrame(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        primary: Color,
        secondary: Color
    ) -> PixelClockPreviewFrame {
        var pixels = blankPixelGrid()
        let mainItem = items.first ?? PixelClockQuotaItem(
            providerID: "openburnbar",
            providerName: "BURN",
            percentUsed: 0,
            usageText: "0%",
            windowLabel: ""
        )

        // Large central number.
        let percent = max(min(remainingPercent(for: mainItem), 99), 0)
        let tens = Character(String(percent / 10))
        let ones = Character(String(percent % 10))
        paintBigGlyph(tens, into: &pixels, originColumn: 4, color: primary)
        paintBigGlyph(ones, into: &pixels, originColumn: 12, color: primary)
        paintGlyph("%", into: &pixels, originColumn: 20, originRow: 2, color: secondary)

        // Right-side mini bars for other providers.
        for (idx, item) in items.prefix(4).enumerated() {
            let column = 26 + idx
            let height = max(min(Int(round(Double(remainingPercent(for: item)) / 100.0 * 6.0)), 6), 0)
            for row in 0..<6 {
                let isLit = (5 - row) < height
                let baseColor = item.percentUsed >= 85 ? primary : secondary
                pixels[row + 1][column] = PixelClockPreviewFrame.Pixel(
                    isLit: isLit,
                    color: baseColor
                )
            }
        }

        return PixelClockPreviewFrame(
            id: identity(config: config, tick: 0, layout: .burnStatus),
            pixels: pixels,
            accessibilityLabel: previewAccessibilityLabel(config: config, item: mainItem)
        )
    }

    private static func alertsOnlyFrame(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        primary: Color,
        secondary: Color
    ) -> PixelClockPreviewFrame {
        var pixels = blankPixelGrid()
        let hottest = items.max(by: { $0.percentUsed < $1.percentUsed })
            ?? PixelClockQuotaItem(
                providerID: "openburnbar",
                providerName: "OK",
                percentUsed: 0,
                usageText: "0%",
                windowLabel: ""
            )
        let isHot = hottest.percentUsed >= 85
        let warnColor = isHot ? primary : secondary

        // Warning glyph (exclamation) when hot.
        if isHot {
            paintGlyph("!", into: &pixels, originColumn: 2, originRow: 1, color: warnColor)
            paintGlyph("!", into: &pixels, originColumn: 6, originRow: 1, color: warnColor)
        } else {
            paintGlyph("O", into: &pixels, originColumn: 2, originRow: 1, color: warnColor)
            paintGlyph("K", into: &pixels, originColumn: 6, originRow: 1, color: warnColor)
        }

        // Provider name + percent.
        let labelChars = Array(hottest.providerName.uppercased().prefix(4))
        for (charIdx, char) in labelChars.enumerated() {
            paintGlyph(char, into: &pixels, originColumn: 12 + charIdx * 4, originRow: 1, color: secondary)
        }

        // Bottom percent bar.
        let barColumns = max(min(Int(round(Double(remainingPercent(for: hottest)) / 100.0 * 30.0)), 30), 0)
        for column in 0..<barColumns {
            pixels[7][column + 1] = PixelClockPreviewFrame.Pixel(
                isLit: true,
                color: warnColor
            )
        }

        return PixelClockPreviewFrame(
            id: identity(config: config, tick: 0, layout: .alertsOnly),
            pixels: pixels,
            accessibilityLabel: previewAccessibilityLabel(config: config, item: hottest)
        )
    }

    // MARK: - Mock data

    /// Deterministic mock content: when the user has selected a subset of
    /// providers, only those show up; otherwise we paint a small default
    /// rotation so designers can see the layout without provider data.
    private static func mockItems(for config: PixelClockConfig) -> [PixelClockQuotaItem] {
        let pool: [PixelClockQuotaItem] = [
            .init(providerID: "claudecode", providerName: "CLD", percentUsed: 72, usageText: "72%", windowLabel: "5H"),
            .init(providerID: "codex", providerName: "CDX", percentUsed: 41, usageText: "41%", windowLabel: "5H"),
            .init(providerID: "factory", providerName: "FAC", percentUsed: 88, usageText: "88%", windowLabel: "WK"),
            .init(providerID: "cursor", providerName: "CUR", percentUsed: 23, usageText: "23%", windowLabel: "MO"),
            .init(providerID: "minimax", providerName: "MMX", percentUsed: 60, usageText: "60%", windowLabel: "MO")
        ]
        let normalized = Set(config.providerIDs.map { $0.lowercased() })
        if normalized.isEmpty { return pool }
        let filtered = pool.filter { normalized.contains($0.providerID.lowercased()) }
        return filtered.isEmpty ? pool : filtered
    }

    // MARK: - Drawing helpers

    private static func blankPixelGrid() -> [[PixelClockPreviewFrame.Pixel]] {
        Array(
            repeating: Array(repeating: PixelClockPreviewFrame.Pixel.off, count: PixelClockPreviewFrame.columns),
            count: PixelClockPreviewFrame.rows
        )
    }

    private static func paintGlyph(
        _ character: Character,
        into pixels: inout [[PixelClockPreviewFrame.Pixel]],
        originColumn: Int,
        originRow: Int,
        color: Color
    ) {
        let glyph = glyph3x5(character)
        for (rowOffset, rowBits) in glyph.enumerated() {
            let row = originRow + rowOffset
            guard row >= 0, row < PixelClockPreviewFrame.rows else { continue }
            for (colOffset, bit) in rowBits.enumerated() {
                let column = originColumn + colOffset
                guard column >= 0, column < PixelClockPreviewFrame.columns else { continue }
                if bit == 1 {
                    pixels[row][column] = PixelClockPreviewFrame.Pixel(isLit: true, color: color)
                }
            }
        }
    }

    private static func paintBigGlyph(
        _ character: Character,
        into pixels: inout [[PixelClockPreviewFrame.Pixel]],
        originColumn: Int,
        color: Color
    ) {
        let glyph = glyph6x7(character)
        for (rowOffset, rowBits) in glyph.enumerated() {
            let row = rowOffset
            guard row >= 0, row < PixelClockPreviewFrame.rows else { continue }
            for (colOffset, bit) in rowBits.enumerated() {
                let column = originColumn + colOffset
                guard column >= 0, column < PixelClockPreviewFrame.columns else { continue }
                if bit == 1 {
                    pixels[row][column] = PixelClockPreviewFrame.Pixel(isLit: true, color: color)
                }
            }
        }
    }

    private static func paintProviderLogo(
        for item: PixelClockQuotaItem,
        into pixels: inout [[PixelClockPreviewFrame.Pixel]]
    ) {
        let logo = PixelClockQuotaRenderer.providerLogo(for: item)
        for row in logo.pixels.indices {
            for column in logo.pixels[row].indices {
                guard let colorHex = logo.colorHex(row: row, column: column) else { continue }
                pixels[row][column] = PixelClockPreviewFrame.Pixel(
                    isLit: true,
                    color: Color(hex: colorHex)
                )
            }
        }
    }

    private static func paintSpinner(
        _ style: PixelClockSpinnerStyle,
        into pixels: inout [[PixelClockPreviewFrame.Pixel]],
        originColumn: Int,
        originRow: Int,
        config: PixelClockConfig,
        tick: Int
    ) {
        let primary = Color(hex: sanitizedHex(config.workingSpinnerPrimaryHex, fallback: config.palette.primaryHex))
        let secondary = Color(hex: sanitizedHex(config.workingSpinnerSecondaryHex, fallback: "#FFFFFF"))
        let points: [(Int, Int, Color)]
        switch style {
        case .orbit:
            let orbit = [(1,0), (3,1), (2,3), (0,2)]
            let active = abs(tick) % orbit.count
            points = orbit.enumerated().map { index, point in (point.0, point.1, index == active ? secondary : primary) }
        case .chase:
            points = (0..<4).map { ($0, 1, ($0 + tick).isMultiple(of: 2) ? secondary : primary) }
        case .pulse:
            points = [(1,1,primary), (2,1,secondary), (1,2,secondary), (2,2,primary)]
        case .scan:
            points = [(abs(tick) % 4, 0, secondary), (abs(tick + 1) % 4, 1, primary), (abs(tick + 2) % 4, 2, primary)]
        }
        for point in points {
            let row = originRow + point.1
            let column = originColumn + point.0
            guard (0..<PixelClockPreviewFrame.rows).contains(row),
                  (0..<PixelClockPreviewFrame.columns).contains(column) else { continue }
            pixels[row][column] = PixelClockPreviewFrame.Pixel(isLit: true, color: point.2)
        }
    }

    private static func identity(
        config: PixelClockConfig,
        tick: Int,
        layout: PixelClockLayout
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(layout.rawValue)
        hasher.combine(config.palette.rawValue)
        hasher.combine(config.providerIDs.sorted())
        hasher.combine(config.timePeriod.rawValue)
        hasher.combine(config.workingSpinnerStyle.rawValue)
        hasher.combine(config.workingSpinnerPrimaryHex)
        hasher.combine(config.workingSpinnerSecondaryHex)
        hasher.combine(tick)
        return hasher.finalize()
    }

    private static func normalizedWindowLabel(_ label: String) -> String {
        let cleaned = label.uppercased().filter { $0.isLetter || $0.isNumber }
        if cleaned == "5H" || cleaned == "7D" { return cleaned }
        return String(cleaned.prefix(2))
    }

    private static func sanitizedHex(_ hex: String, fallback: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, Int(raw, radix: 16) != nil else { return fallback }
        return "#\(raw.uppercased())"
    }

    private static func previewAccessibilityLabel(
        config: PixelClockConfig,
        item: PixelClockQuotaItem
    ) -> String {
        let layout = config.layout.displayName
        let palette = config.palette.displayName
        return "Pixel clock preview, \(layout), \(palette) palette, showing \(item.providerName) \(remainingPercent(for: item)) percent remaining"
    }

    private static func remainingPercent(for item: PixelClockQuotaItem) -> Int {
        min(max(100 - item.percentUsed, 0), 100)
    }

    // MARK: - 3×5 Glyph font (a small subset is enough for previews)

    private static func glyph3x5(_ character: Character) -> [[Int]] {
        switch character {
        case "0": return [[1,1,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]]
        case "1": return [[0,1,0],[1,1,0],[0,1,0],[0,1,0],[1,1,1]]
        case "2": return [[1,1,1],[0,0,1],[1,1,1],[1,0,0],[1,1,1]]
        case "3": return [[1,1,1],[0,0,1],[1,1,1],[0,0,1],[1,1,1]]
        case "4": return [[1,0,1],[1,0,1],[1,1,1],[0,0,1],[0,0,1]]
        case "5": return [[1,1,1],[1,0,0],[1,1,1],[0,0,1],[1,1,1]]
        case "6": return [[1,1,1],[1,0,0],[1,1,1],[1,0,1],[1,1,1]]
        case "7": return [[1,1,1],[0,0,1],[0,1,0],[0,1,0],[0,1,0]]
        case "8": return [[1,1,1],[1,0,1],[1,1,1],[1,0,1],[1,1,1]]
        case "9": return [[1,1,1],[1,0,1],[1,1,1],[0,0,1],[1,1,1]]
        case "%": return [[1,0,1],[0,0,1],[0,1,0],[1,0,0],[1,0,1]]
        case "!": return [[1,0,0],[1,0,0],[1,0,0],[0,0,0],[1,0,0]]
        case "A": return [[0,1,0],[1,0,1],[1,1,1],[1,0,1],[1,0,1]]
        case "B": return [[1,1,0],[1,0,1],[1,1,0],[1,0,1],[1,1,0]]
        case "C": return [[0,1,1],[1,0,0],[1,0,0],[1,0,0],[0,1,1]]
        case "D": return [[1,1,0],[1,0,1],[1,0,1],[1,0,1],[1,1,0]]
        case "E": return [[1,1,1],[1,0,0],[1,1,0],[1,0,0],[1,1,1]]
        case "F": return [[1,1,1],[1,0,0],[1,1,0],[1,0,0],[1,0,0]]
        case "G": return [[0,1,1],[1,0,0],[1,0,1],[1,0,1],[0,1,1]]
        case "H": return [[1,0,1],[1,0,1],[1,1,1],[1,0,1],[1,0,1]]
        case "I": return [[1,1,1],[0,1,0],[0,1,0],[0,1,0],[1,1,1]]
        case "J": return [[0,0,1],[0,0,1],[0,0,1],[1,0,1],[0,1,0]]
        case "K": return [[1,0,1],[1,1,0],[1,0,0],[1,1,0],[1,0,1]]
        case "L": return [[1,0,0],[1,0,0],[1,0,0],[1,0,0],[1,1,1]]
        case "M": return [[1,0,1],[1,1,1],[1,1,1],[1,0,1],[1,0,1]]
        case "N": return [[1,0,1],[1,1,1],[1,1,1],[1,1,1],[1,0,1]]
        case "O": return [[0,1,0],[1,0,1],[1,0,1],[1,0,1],[0,1,0]]
        case "P": return [[1,1,0],[1,0,1],[1,1,0],[1,0,0],[1,0,0]]
        case "Q": return [[0,1,0],[1,0,1],[1,0,1],[1,1,1],[0,1,1]]
        case "R": return [[1,1,0],[1,0,1],[1,1,0],[1,0,1],[1,0,1]]
        case "S": return [[0,1,1],[1,0,0],[0,1,0],[0,0,1],[1,1,0]]
        case "T": return [[1,1,1],[0,1,0],[0,1,0],[0,1,0],[0,1,0]]
        case "U": return [[1,0,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]]
        case "V": return [[1,0,1],[1,0,1],[1,0,1],[1,0,1],[0,1,0]]
        case "W": return [[1,0,1],[1,0,1],[1,1,1],[1,1,1],[1,0,1]]
        case "X": return [[1,0,1],[1,0,1],[0,1,0],[1,0,1],[1,0,1]]
        case "Y": return [[1,0,1],[1,0,1],[0,1,0],[0,1,0],[0,1,0]]
        case "Z": return [[1,1,1],[0,0,1],[0,1,0],[1,0,0],[1,1,1]]
        default:
            return [[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0]]
        }
    }

    private static func glyph6x7(_ character: Character) -> [[Int]] {
        switch character {
        case "0": return [
            [0,1,1,1,1,0],
            [1,0,0,0,0,1],
            [1,0,0,0,1,1],
            [1,0,0,1,0,1],
            [1,1,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,0]
        ]
        case "1": return [
            [0,0,1,1,0,0],
            [0,1,1,1,0,0],
            [0,0,1,1,0,0],
            [0,0,1,1,0,0],
            [0,0,1,1,0,0],
            [0,0,1,1,0,0],
            [0,1,1,1,1,0]
        ]
        case "2": return [
            [0,1,1,1,1,0],
            [1,0,0,0,0,1],
            [0,0,0,0,1,0],
            [0,0,0,1,0,0],
            [0,0,1,0,0,0],
            [0,1,0,0,0,0],
            [1,1,1,1,1,1]
        ]
        case "3": return [
            [0,1,1,1,1,0],
            [1,0,0,0,0,1],
            [0,0,0,0,0,1],
            [0,0,1,1,1,0],
            [0,0,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,0]
        ]
        case "4": return [
            [0,0,0,0,1,0],
            [0,0,0,1,1,0],
            [0,0,1,0,1,0],
            [0,1,0,0,1,0],
            [1,1,1,1,1,1],
            [0,0,0,0,1,0],
            [0,0,0,0,1,0]
        ]
        case "5": return [
            [1,1,1,1,1,1],
            [1,0,0,0,0,0],
            [1,0,0,0,0,0],
            [1,1,1,1,1,0],
            [0,0,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,0]
        ]
        case "6": return [
            [0,0,1,1,1,0],
            [0,1,0,0,0,0],
            [1,0,0,0,0,0],
            [1,1,1,1,1,0],
            [1,0,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,0]
        ]
        case "7": return [
            [1,1,1,1,1,1],
            [0,0,0,0,0,1],
            [0,0,0,0,1,0],
            [0,0,0,1,0,0],
            [0,0,1,0,0,0],
            [0,1,0,0,0,0],
            [1,0,0,0,0,0]
        ]
        case "8": return [
            [0,1,1,1,1,0],
            [1,0,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,0],
            [1,0,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,0]
        ]
        case "9": return [
            [0,1,1,1,1,0],
            [1,0,0,0,0,1],
            [1,0,0,0,0,1],
            [0,1,1,1,1,1],
            [0,0,0,0,0,1],
            [0,0,0,0,1,0],
            [0,1,1,1,0,0]
        ]
        default:
            return Array(repeating: Array(repeating: 0, count: 6), count: 7)
        }
    }
}

// MARK: - Display Name Helpers

public extension PixelClockLayout {
    var displayName: String {
        switch self {
        case .providerDashboard: return "Provider dashboard"
        case .quotaCarousel: return "Quota carousel"
        case .burnStatus:    return "Burn status"
        case .alertsOnly:    return "Alerts only"
        }
    }

    var iconName: String {
        switch self {
        case .providerDashboard: return "rectangle.grid.2x2"
        case .quotaCarousel: return "rectangle.split.3x1"
        case .burnStatus:    return "flame"
        case .alertsOnly:    return "exclamationmark.bubble"
        }
    }
}

public extension PixelClockPalette {
    var displayName: String {
        switch self {
        case .emberWhimsy: return "Ember & whimsy"
        case .mercury:     return "Mercury"
        case .traffic:     return "Traffic"
        case .monochrome:  return "Monochrome"
        case .rainbow:     return "Pride rainbow"
        }
    }
}

public extension PixelClockProbeStatus {
    var displayName: String {
        switch self {
        case .unknown:              return "Not detected"
        case .awtrixReady:          return "AWTRIX ready"
        case .stockUlanziFirmware:  return "Stock Ulanzi firmware"
        case .unreachable:          return "Unreachable"
        case .unsupported:          return "Unsupported response"
        case .error:                return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:              return "questionmark.circle"
        case .awtrixReady:          return "bolt.horizontal.circle.fill"
        case .stockUlanziFirmware:  return "exclamationmark.triangle.fill"
        case .unreachable:          return "wifi.exclamationmark"
        case .unsupported:          return "questionmark.app.dashed"
        case .error:                return "xmark.octagon"
        }
    }

    var isReady: Bool { self == .awtrixReady }
    var requiresAttention: Bool {
        switch self {
        case .stockUlanziFirmware, .unreachable, .unsupported, .error:
            return true
        case .awtrixReady, .unknown:
            return false
        }
    }
}
