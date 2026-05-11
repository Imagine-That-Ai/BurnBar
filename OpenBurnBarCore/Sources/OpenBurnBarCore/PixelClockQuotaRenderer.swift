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
        pages.map { page in
            var payload: [String: Any] = [
                "text": page.draw.isEmpty ? page.text : "",
                "color": page.color,
                "duration": page.durationSeconds,
                "scrollSpeed": page.scrollSpeed,
                "lifetime": max(config.clampedUpdateInterval * 2, 60),
                "save": false
            ]
            if !page.draw.isEmpty {
                payload["draw"] = page.draw.map(\.awtrixObject)
                payload["noScroll"] = true
            }
            if let progress = page.progress {
                payload["progress"] = progress
                payload["progressC"] = page.color
                payload["progressBC"] = "#181818"
            }
            return payload
        }
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
            return [dashboardPage(for: waiting, config: config, isWorking: isWorking)]
        }

        return selectedItems.map { item in
            dashboardPage(for: item, config: config, isWorking: isWorking)
        }
    }

    private static func dashboardPage(
        for item: PixelClockQuotaItem,
        config: PixelClockConfig,
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
            draw: dashboardDraw(for: item, config: config, isWorking: isWorking)
        )
    }

    private static func dashboardDraw(
        for item: PixelClockQuotaItem,
        config: PixelClockConfig,
        isWorking: Bool
    ) -> [PixelClockDrawInstruction] {
        var draw: [PixelClockDrawInstruction] = []
        let primary = providerAccentHex(for: item, fallback: config.palette.hexColor(for: item.percentUsed))
        let status = isWorking ? PixelClockAgentStatus.running : item.agentStatus
        let remaining = remainingPercent(for: item)

        draw.append(contentsOf: providerLogoDraw(for: item))

        let window = normalizedWindowLabel(item.windowLabel)
        if !window.isEmpty {
            draw.append(contentsOf: miniTextDraw(window, x: 10, y: 1, color: primary))
        }

        let metricText = status == .ready ? "\(remaining)%" : shortStatusText(status)
        let metricX = max(17, 32 - metricText.count * 4)
        draw.append(contentsOf: miniTextDraw(metricText, x: metricX, y: 1, color: primary))

        let filled = min(max(Int(round(Double(remaining) / 100.0 * 21.0)), 0), 21)
        if filled > 0 {
            draw.append(.fillRect(x: 10, y: 7, width: filled, height: 1, color: primary))
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
            points = [(1,0,secondary), (3,1,primary), (2,3,secondary), (0,2,primary)]
        case .chase:
            points = [(0,1,primary), (1,1,secondary), (2,1,primary), (3,1,secondary)]
        case .pulse:
            points = [(1,1,primary), (2,1,secondary), (1,2,secondary), (2,2,primary)]
        case .scan:
            points = [(0,0,primary), (1,1,secondary), (2,2,primary), (3,3,secondary)]
        }
        return points.map { point in .pixel(x: x + point.0, y: y + point.1, color: point.2) }
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
        if cleaned == "5H" || cleaned == "7D" { return cleaned }
        return String(cleaned.prefix(2))
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
}
