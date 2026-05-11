import Foundation

// MARK: - Pixel Clock Provider Logo

struct PixelClockProviderLogo: Equatable {
    let sourceName: String
    let pixels: [[String?]]

    init(sourceName: String, pixels: [[String?]]) {
        self.sourceName = sourceName
        self.pixels = pixels
    }

    init(sourceName: String, rows: [String], colors: [Character: String]) {
        self.sourceName = sourceName
        self.pixels = rows.map { row in
            row.map { pixel in
                if pixel == "." { return nil }
                return colors[pixel] ?? "#FAFAFA"
            }
        }
    }

    var rows: [String] {
        pixels.map { row in
            String(row.map { $0 == nil ? "." : "#" })
        }
    }

    func colorHex(row: Int, column: Int) -> String? {
        guard row >= 0, row < pixels.count,
              column >= 0, column < pixels[row].count else {
            return nil
        }
        return pixels[row][column]
    }
}

// MARK: - Pixel Clock Quota Renderer

public enum PixelClockQuotaRenderer {
    public static let appName = "openburnbar"
    private static let maxAWTRIXDrawInstructionCount = 20

    public static func renderPages(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        now: Date = Date(),
        isWorking: Bool = false
    ) -> [PixelClockRenderedPage] {
        switch config.layout {
        case .providerDashboard, .quotaCarousel:
            return renderProviderDashboard(items: items, config: config, now: now, isWorking: isWorking)
        case .burnStatus, .alertsOnly:
            return renderQuotaCarousel(items: items, config: config, now: now)
        }
    }

    public static func renderQuotaCarousel(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        now: Date = Date()
    ) -> [PixelClockRenderedPage] {
        let selectedItems = filteredItems(items, providerIDs: config.providerIDs)
        guard !selectedItems.isEmpty else {
            return [
                PixelClockRenderedPage(
                    text: "OPENBURNBAR WAITING",
                    color: config.palette.primaryHex,
                    durationSeconds: config.clampedPageDuration,
                    scrollSpeed: config.clampedScrollSpeed
                )
            ]
        }

        var pages: [PixelClockRenderedPage] = [
            PixelClockRenderedPage(
                text: "OPENBURNBAR \(selectedItems.count) TRACKED",
                color: config.palette.primaryHex,
                durationSeconds: config.clampedPageDuration,
                scrollSpeed: config.clampedScrollSpeed
            )
        ]

        pages.append(contentsOf: selectedItems.map { item in
            PixelClockRenderedPage(
                text: compactText(for: item),
                color: config.palette.hexColor(for: item.percentUsed),
                durationSeconds: config.clampedPageDuration,
                progress: remainingPercent(for: item),
                scrollSpeed: config.clampedScrollSpeed
            )
        })
        return pages
    }

    public static func awtrixPayload(
        pages: [PixelClockRenderedPage],
        config: PixelClockConfig
    ) -> [[String: Any]] {
        let lifetimeSeconds = awtrixCustomAppLifetimeSeconds(pages: pages, config: config)
        return pages.map { page in
            let safeDraw = bitmapDraw(from: page.draw).map { [$0] } ?? safeAWTRIXDraw(page.draw)
            var payload: [String: Any] = [
                "text": safeDraw.isEmpty ? page.text : "",
                "color": page.color,
                "duration": page.durationSeconds,
                "scrollSpeed": page.scrollSpeed,
                "lifetime": lifetimeSeconds,
                "save": false
            ]
            if !safeDraw.isEmpty {
                payload["draw"] = safeDraw.map(\.awtrixObject)
                payload["noScroll"] = true
            }
            if safeDraw.isEmpty, let progress = page.progress {
                payload["progress"] = progress
                payload["progressC"] = page.color
                payload["progressBC"] = "#181818"
            }
            return payload
        }
    }

    private static func bitmapDraw(from draw: [PixelClockDrawInstruction]) -> PixelClockDrawInstruction? {
        guard !draw.isEmpty else { return nil }
        var pixels = Array(repeating: 0, count: 32 * 8)

        func paint(x: Int, y: Int, color: String) {
            guard (0..<32).contains(x), (0..<8).contains(y) else { return }
            pixels[y * 32 + x] = rgbInt(fromHex: sanitizedHex(color, fallback: "#FFFFFF"))
        }

        for instruction in draw {
            switch instruction.command {
            case .drawPixel:
                guard instruction.values.count == 3,
                      case .int(let x) = instruction.values[0],
                      case .int(let y) = instruction.values[1],
                      case .string(let color) = instruction.values[2] else {
                    return nil
                }
                paint(x: x, y: y, color: color)
            case .fillRect:
                guard instruction.values.count == 5,
                      case .int(let x) = instruction.values[0],
                      case .int(let y) = instruction.values[1],
                      case .int(let width) = instruction.values[2],
                      case .int(let height) = instruction.values[3],
                      case .string(let color) = instruction.values[4] else {
                    return nil
                }
                for yy in y..<y + max(0, height) {
                    for xx in x..<x + max(0, width) {
                        paint(x: xx, y: yy, color: color)
                    }
                }
            case .drawText, .drawBitmap:
                return nil
            }
        }

        return .bitmap(x: 0, y: 0, width: 32, height: 8, pixels: pixels)
    }

    private static func rgbInt(fromHex hex: String) -> Int {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return 0xFFFFFF
        }
        return value
    }

    private static func awtrixCustomAppLifetimeSeconds(
        pages: [PixelClockRenderedPage],
        config: PixelClockConfig
    ) -> Int {
        let cycleDuration = pages.reduce(0) { total, page in
            total + max(page.durationSeconds, 1)
        }
        // AWTRIX removes volatile custom apps after `lifetime`. The
        // controller may intentionally wait for a full page cycle before
        // repushing identical payloads; keep app lifetime comfortably above
        // that cycle so a clock reboot or long provider carousel does not
        // decay into a black screen between heartbeats.
        return max(900, cycleDuration * 3, config.clampedUpdateInterval * 4, 60)
    }

    private static func safeAWTRIXDraw(_ draw: [PixelClockDrawInstruction]) -> [PixelClockDrawInstruction] {
        guard !draw.isEmpty else { return [] }
        let compacted = compactPixelDrawIntoRuns(draw)
        let candidate = compacted ?? draw
        guard candidate.count <= maxAWTRIXDrawInstructionCount else {
            // AWTRIX Light firmware can freeze or return HTTP 500 when custom
            // apps contain very large draw lists. A text/progress fallback is
            // less pretty, but it is always better than blanking the clock.
            return []
        }
        return candidate
    }

    private static func compactPixelDrawIntoRuns(_ draw: [PixelClockDrawInstruction]) -> [PixelClockDrawInstruction]? {
        var pixels = Array(repeating: String?.none, count: 32 * 8)

        func paint(x: Int, y: Int, color: String) {
            guard (0..<32).contains(x), (0..<8).contains(y) else { return }
            pixels[y * 32 + x] = sanitizedHex(color, fallback: "#FFFFFF")
        }

        for instruction in draw {
            switch instruction.command {
            case .drawPixel:
                guard instruction.values.count == 3,
                      case .int(let x) = instruction.values[0],
                      case .int(let y) = instruction.values[1],
                      case .string(let color) = instruction.values[2] else {
                    return draw
                }
                paint(x: x, y: y, color: color)
            case .fillRect:
                guard instruction.values.count == 5,
                      case .int(let x) = instruction.values[0],
                      case .int(let y) = instruction.values[1],
                      case .int(let width) = instruction.values[2],
                      case .int(let height) = instruction.values[3],
                      case .string(let color) = instruction.values[4] else {
                    return draw
                }
                for yy in y..<y + max(0, height) {
                    for xx in x..<x + max(0, width) {
                        paint(x: xx, y: yy, color: color)
                    }
                }
            case .drawText, .drawBitmap:
                return nil
            }
        }

        var compacted: [PixelClockDrawInstruction] = []
        for y in 0..<8 {
            var x = 0
            while x < 32 {
                guard let color = pixels[y * 32 + x] else {
                    x += 1
                    continue
                }
                var width = 1
                while x + width < 32, pixels[y * 32 + x + width] == color {
                    width += 1
                }
                if width == 1 {
                    compacted.append(.pixel(x: x, y: y, color: color))
                } else {
                    compacted.append(.fillRect(x: x, y: y, width: width, height: 1, color: color))
                }
                x += width
            }
        }
        return compacted
    }

    private static func renderProviderDashboard(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        now: Date,
        isWorking: Bool
    ) -> [PixelClockRenderedPage] {
        let selectedItems = filteredItems(items, providerIDs: config.providerIDs)
        guard !selectedItems.isEmpty else {
            let waiting = PixelClockQuotaItem(
                providerID: "openburnbar",
                providerName: "OpenBurnBar",
                percentUsed: 0,
                usageText: "waiting",
                windowLabel: ""
            )
            return [dashboardPage(for: waiting, config: config, now: now, isWorking: isWorking)]
        }

        return selectedItems.map { item in
            dashboardPage(for: item, config: config, now: now, isWorking: isWorking)
        }
    }

    private static func dashboardPage(
        for item: PixelClockQuotaItem,
        config: PixelClockConfig,
        now: Date,
        isWorking: Bool
    ) -> PixelClockRenderedPage {
        let color = providerAccentHex(for: item, fallback: config.palette.hexColor(for: item.percentUsed))
        let provider = shortProviderCode(for: item)
        let status = isWorking ? PixelClockAgentStatus.running : item.agentStatus
        let statusText = status == .ready
            ? "\(remainingPercent(for: item))%"
            : "\(status.displayText) \(remainingPercent(for: item))%"
        return PixelClockRenderedPage(
            text: "\(provider) \(normalizedWindowLabel(item.windowLabel)) \(statusText) \(item.usageText)",
            color: color,
            durationSeconds: config.clampedPageDuration,
            progress: remainingPercent(for: item),
            scrollSpeed: config.clampedScrollSpeed,
            draw: dashboardDraw(for: item, config: config, now: now, isWorking: isWorking)
        )
    }

    private static func dashboardDraw(
        for item: PixelClockQuotaItem,
        config: PixelClockConfig,
        now: Date,
        isWorking: Bool
    ) -> [PixelClockDrawInstruction] {
        var draw: [PixelClockDrawInstruction] = []
        let primary = providerAccentHex(for: item, fallback: config.palette.hexColor(for: item.percentUsed))
        let status = isWorking ? PixelClockAgentStatus.running : item.agentStatus
        let remaining = remainingPercent(for: item)

        draw.append(contentsOf: providerLogoDraw(for: item))

        let window = normalizedWindowLabel(item.windowLabel)
        if !window.isEmpty {
            draw.append(contentsOf: windowTextDraw(window, x: 10, y: 1, color: primary))
        }

        if status == .running {
            let tick = Int(now.timeIntervalSince1970.rounded(.down))
            draw.append(contentsOf: spinnerDraw(config.workingSpinnerStyle, x: 24, y: 1, config: config, tick: tick))
        } else {
            let metricText = dashboardMetricText(status: status, remaining: remaining)
            let metricX = dashboardMetricOriginX(for: metricText)
            draw.append(contentsOf: miniTextDraw(metricText, x: metricX, y: 1, color: primary))
        }

        let filled = min(max(Int(round(Double(remaining) / 100.0 * 20.0)), 0), 20)
        if filled > 0 {
            draw.append(.fillRect(x: 12, y: 7, width: filled, height: 1, color: primary))
        }
        return draw
    }

    private static func spinnerDraw(
        _ style: PixelClockSpinnerStyle,
        x: Int,
        y: Int,
        config: PixelClockConfig,
        tick: Int
    ) -> [PixelClockDrawInstruction] {
        let primary = sanitizedHex(config.workingSpinnerPrimaryHex, fallback: config.palette.primaryHex)
        let secondary = sanitizedHex(config.workingSpinnerSecondaryHex, fallback: "#FFFFFF")
        let points: [(Int, Int, String)]
        switch style {
        case .orbit:
            let ring = [(2,0), (3,0), (4,1), (5,2), (4,3), (3,4), (2,4), (1,3), (0,2), (1,1)]
            let active = positiveModulo(tick, ring.count)
            points = ring.enumerated().map { index, point in
                (point.0, point.1, index == active ? primary : secondary)
            }
        case .chase:
            let active = positiveModulo(tick, 6)
            points = (0..<6).map { index in (index, 2, index == active ? primary : secondary) }
        case .pulse:
            let flip = positiveModulo(tick, 2) == 0
            points = [
                (2, 1, flip ? primary : secondary),
                (3, 1, flip ? secondary : primary),
                (1, 2, flip ? secondary : primary),
                (4, 2, flip ? primary : secondary),
                (2, 3, flip ? primary : secondary),
                (3, 3, flip ? secondary : primary)
            ]
        case .scan:
            let offset = positiveModulo(tick, 6)
            points = (0..<5).map { index in
                let column = (index + offset) % 6
                return (column, index, index == 0 ? primary : secondary)
            }
        }
        return points.map { point in .pixel(x: x + point.0, y: y + point.1, color: point.2) }
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private static func providerLogoDraw(for item: PixelClockQuotaItem) -> [PixelClockDrawInstruction] {
        let logo = providerLogo(for: item)
        var draw: [PixelClockDrawInstruction] = []
        for row in logo.pixels.indices {
            for column in logo.pixels[row].indices {
                guard let color = logo.colorHex(row: row, column: column) else { continue }
                draw.append(.pixel(x: column, y: row, color: color))
            }
        }
        return draw
    }

    static func providerLogoPattern(for item: PixelClockQuotaItem) -> [String] {
        providerLogo(for: item).rows
    }

    static func providerLogo(for item: PixelClockQuotaItem) -> PixelClockProviderLogo {
        let token = "\(item.providerID) \(item.providerName)".lowercased()
        if token.contains("claude") {
            return PixelClockProviderLogoAssets.claudeCode
        }
        if token.contains("codex") || token.contains("openai") {
            return PixelClockProviderLogoAssets.codex
        }
        if token.contains("factory") || token.contains("droid") {
            return PixelClockProviderLogoAssets.factory
        }
        if token.contains("cursor") {
            return PixelClockProviderLogoAssets.cursor
        }
        if token.contains("warp") {
            return PixelClockProviderLogoAssets.warp
        }
        if token.contains("copilot") {
            return PixelClockProviderLogoAssets.copilot
        }
        if token.contains("kimi") {
            return PixelClockProviderLogoAssets.kimi
        }
        if token.contains("ollama") {
            return PixelClockProviderLogoAssets.ollama
        }
        if token.contains("minimax") {
            return PixelClockProviderLogoAssets.miniMax
        }
        if token.contains("z.ai") || token.contains("zai") {
            return PixelClockProviderLogoAssets.zai
        }
        return PixelClockProviderLogo(
            sourceName: "monogram",
            rows: monogramPattern(for: shortProviderCode(for: item)),
            colors: [
                "1": "#FAFAFA",
                "2": "#A0A0A0"
            ]
        )
    }

    private static func monogramPattern(for code: String) -> [String] {
        var rows = Array(repeating: Array(repeating: ".", count: 8), count: 8)
        let chars = Array(code.uppercased().prefix(2))
        for (index, char) in chars.enumerated() {
            let glyph = glyph3x5(char)
            let x = index == 0 ? 0 : 4
            for (row, bits) in glyph.enumerated() {
                for (column, bit) in bits.enumerated() where bit == 1 {
                    rows[row + 1][x + column] = "1"
                }
            }
        }
        return rows.map { $0.joined() }
    }

    private static func miniTextDraw(
        _ text: String,
        x: Int,
        y: Int,
        color: String
    ) -> [PixelClockDrawInstruction] {
        var draw: [PixelClockDrawInstruction] = []
        for (index, char) in text.uppercased().enumerated() {
            let glyph = glyph3x5(char)
            let originX = x + index * 4
            for (row, bits) in glyph.enumerated() {
                for (column, bit) in bits.enumerated() where bit == 1 {
                    draw.append(.pixel(x: originX + column, y: y + row, color: color))
                }
            }
        }
        return draw
    }

    private static func windowTextDraw(
        _ text: String,
        x: Int,
        y: Int,
        color: String
    ) -> [PixelClockDrawInstruction] {
        var draw: [PixelClockDrawInstruction] = []
        var cursorX = x
        for char in text {
            let glyph = windowGlyph(char)
            for (row, bits) in glyph.enumerated() {
                for (column, bit) in bits.enumerated() where bit == 1 {
                    draw.append(.pixel(x: cursorX + column, y: y + row, color: color))
                }
            }
            cursorX += (glyph.first?.count ?? 0) + 1
        }
        return draw
    }

    private static func filteredItems(
        _ items: [PixelClockQuotaItem],
        providerIDs: [String]
    ) -> [PixelClockQuotaItem] {
        let normalized = Set(providerIDs.map { $0.lowercased() })
        guard !normalized.isEmpty else { return items }
        return items.filter { item in
            normalized.contains(item.providerID.lowercased())
        }
    }

    private static func compactText(for item: PixelClockQuotaItem) -> String {
        let provider = item.providerName
            .replacingOccurrences(of: "Claude Code", with: "Claude")
            .replacingOccurrences(of: "Factory / Droid", with: "Factory")
        let window = item.windowLabel.isEmpty ? "" : " \(item.windowLabel)"
        return "\(provider)\(window) \(item.percentUsed)% \(item.usageText)"
    }

    private static func shortProviderCode(for item: PixelClockQuotaItem) -> String {
        let token = "\(item.providerID) \(item.providerName)".lowercased()
        if token.contains("claude") { return "CLD" }
        if token.contains("codex") { return "CDX" }
        if token.contains("factory") || token.contains("droid") { return "FAC" }
        if token.contains("copilot") { return "COP" }
        if token.contains("minimax") { return "MMX" }
        if token.contains("cursor") { return "CUR" }
        if token.contains("warp") { return "WRP" }
        if token.contains("ollama") { return "OLL" }
        if token.contains("kimi") { return "KIM" }
        if token.contains("z.ai") || token.contains("zai") { return "ZAI" }
        let normalized = item.providerName
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        return String(normalized.prefix(3)).isEmpty ? "OBB" : String(normalized.prefix(3))
    }

    private static func normalizedWindowLabel(_ label: String) -> String {
        let cleaned = label.uppercased().filter { $0.isLetter || $0.isNumber }
        switch cleaned {
        case "5H": return "5h"
        case "7D": return "7d"
        case "24H": return "24h"
        case "30D": return "30d"
        default: return String(cleaned.prefix(2))
        }
    }

    private static func dashboardMetricText(status: PixelClockAgentStatus, remaining: Int) -> String {
        guard status == .ready else { return shortStatusText(status) }
        return remaining >= 100 ? "100" : "\(remaining)%"
    }

    private static func dashboardMetricOriginX(for text: String) -> Int {
        let clampedCount = min(max(text.count, 1), 3)
        return 33 - clampedCount * 4
    }

    private static func remainingPercent(for item: PixelClockQuotaItem) -> Int {
        min(max(100 - item.percentUsed, 0), 100)
    }

    private static func sanitizedHex(_ hex: String, fallback: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, Int(raw, radix: 16) != nil else { return fallback }
        return "#\(raw.uppercased())"
    }

    private static func providerAccentHex(for item: PixelClockQuotaItem, fallback: String) -> String {
        let token = "\(item.providerID) \(item.providerName)".lowercased()
        if token.contains("claude") { return "#D97757" }
        if token.contains("codex") || token.contains("openai") { return "#8EA0FF" }
        if token.contains("factory") || token.contains("droid") { return "#FFFFFF" }
        if token.contains("minimax") { return "#EC1970" }
        if token.contains("z.ai") || token.contains("zai") { return "#C9B6FF" }
        if token.contains("cursor") { return "#FFFFFF" }
        if token.contains("warp") { return "#D4DADE" }
        if token.contains("copilot") { return "#2BA1AF" }
        if token.contains("kimi") { return "#136CD2" }
        if token.contains("ollama") { return "#F2F2F2" }
        return fallback
    }

    private static func shortStatusText(_ status: PixelClockAgentStatus) -> String {
        switch status {
        case .ready: return "OK"
        case .running: return "RUN"
        case .completed: return "DONE"
        case .failed: return "ERR"
        }
    }

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

    private static func windowGlyph(_ character: Character) -> [[Int]] {
        switch character {
        case "0": return glyph3x5("0")
        case "1": return glyph3x5("1")
        case "2": return glyph3x5("2")
        case "3": return glyph3x5("3")
        case "4": return glyph3x5("4")
        case "5": return glyph3x5("5")
        case "6": return glyph3x5("6")
        case "7": return glyph3x5("7")
        case "8": return glyph3x5("8")
        case "9": return glyph3x5("9")
        case "d": return [[0,0,1],[0,0,1],[0,1,1],[1,0,1],[0,1,1]]
        case "h": return [[1,0,0],[1,0,0],[1,1,0],[1,0,1],[1,0,1]]
        default: return [[0,0],[0,0],[0,0],[0,0],[0,0]]
        }
    }
}
