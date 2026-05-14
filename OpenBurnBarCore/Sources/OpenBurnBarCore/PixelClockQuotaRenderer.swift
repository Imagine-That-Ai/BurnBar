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
        // `.burnStatus` / `.alertsOnly` normally render scrolling text via
        // AWTRIX's native renderer. When an agent is currently working the
        // text mode can't show a pixel spinner overlay (AWTRIX drops the
        // scrolling text whenever a custom draw list is attached), so we
        // promote those layouts to the bitmap dashboard for the duration of
        // the run. The user gets the working indicator without losing data —
        // when the agent finishes, we fall back to the configured layout.
        switch config.layout {
        case .providerDashboard, .quotaCarousel:
            return renderProviderDashboard(items: items, config: config, now: now, isWorking: isWorking)
        case .burnStatus, .alertsOnly:
            if isWorking {
                return renderProviderDashboard(items: items, config: config, now: now, isWorking: true)
            }
            return renderQuotaCarousel(items: items, config: config, now: now)
        }
    }

    public static func renderQuotaCarousel(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig,
        now: Date = Date()
    ) -> [PixelClockRenderedPage] {
        let selectedItems = selectedItems(items: items, config: config)
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
        let selectedItems = selectedItems(items: items, config: config)
        guard !selectedItems.isEmpty else {
            let waiting = PixelClockQuotaItem(
                providerID: "openburnbar",
                providerName: "OpenBurnBar",
                percentUsed: 0,
                usageText: "waiting",
                windowLabel: ""
            )
            return [dashboardPage(for: waiting, pageIndex: 0, config: config, now: now, isWorking: isWorking)]
        }

        return selectedItems.enumerated().map { index, item in
            dashboardPage(for: item, pageIndex: index, config: config, now: now, isWorking: isWorking)
        }
    }

    private static func dashboardPage(
        for item: PixelClockQuotaItem,
        pageIndex: Int,
        config: PixelClockConfig,
        now: Date,
        isWorking: Bool
    ) -> PixelClockRenderedPage {
        let color = accentHex(for: item, pageIndex: pageIndex, config: config)
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
            draw: dashboardDraw(for: item, pageIndex: pageIndex, config: config, now: now, isWorking: isWorking)
        )
    }

    private static func dashboardDraw(
        for item: PixelClockQuotaItem,
        pageIndex: Int,
        config: PixelClockConfig,
        now: Date,
        isWorking: Bool
    ) -> [PixelClockDrawInstruction] {
        var draw: [PixelClockDrawInstruction] = []
        let primary = accentHex(for: item, pageIndex: pageIndex, config: config)
        let status = isWorking ? PixelClockAgentStatus.running : item.agentStatus
        let remaining = remainingPercent(for: item)
        let isRainbow = config.palette.isRainbow

        if isRainbow {
            draw.append(contentsOf: rainbowLogoDraw(for: item, pageIndex: pageIndex))
        } else {
            draw.append(contentsOf: providerLogoDraw(for: item, tint: nil))
        }

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

        if status == .running {
            let tick = Int(now.timeIntervalSince1970.rounded(.down))
            draw.append(contentsOf: spinnerDraw(config.workingSpinnerStyle, x: 27, y: 3, config: config, tick: tick))
        }

        let filled = min(max(Int(round(Double(remaining) / 100.0 * 21.0)), 0), 21)
        if isRainbow {
            // Always paint the full 21-px rainbow flag at row 7; overlay a dim
            // mask over the unused portion so the rainbow stays visible at any %.
            draw.append(contentsOf: rainbowBarDraw(x: 10, y: 7, width: 21))
            if filled < 21 {
                let unusedX = 10 + filled
                let unusedW = 21 - filled
                draw.append(.fillRect(x: unusedX, y: 7, width: unusedW, height: 1, color: "#181818"))
            }
        } else if filled > 0 {
            draw.append(.fillRect(x: 10, y: 7, width: filled, height: 1, color: primary))
        }
        return draw
    }

    /// Returns the per-page accent color, honoring the rainbow palette by
    /// cycling through the pride flag based on `pageIndex`.
    private static func accentHex(
        for item: PixelClockQuotaItem,
        pageIndex: Int,
        config: PixelClockConfig
    ) -> String {
        if config.palette.isRainbow {
            return config.palette.rainbowColor(at: pageIndex)
        }
        return providerAccentHex(
            for: item,
            fallback: config.palette.hexColor(for: item.percentUsed)
        )
    }

    /// 21-column rainbow bar at the given origin. Stripe widths sum to 21:
    /// [4, 4, 3, 4, 3, 3].
    private static func rainbowBarDraw(x: Int, y: Int, width: Int) -> [PixelClockDrawInstruction] {
        let flag = PixelClockPalette.rainbowFlag
        let widths = [4, 4, 3, 4, 3, 3]
        var draw: [PixelClockDrawInstruction] = []
        var cursor = x
        for (index, stripe) in widths.enumerated() {
            guard cursor < x + width else { break }
            let remaining = (x + width) - cursor
            let stripeWidth = min(stripe, remaining)
            draw.append(.fillRect(x: cursor, y: y, width: stripeWidth, height: 1, color: flag[index]))
            cursor += stripeWidth
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

    private static func providerLogoDraw(
        for item: PixelClockQuotaItem,
        tint: String? = nil
    ) -> [PixelClockDrawInstruction] {
        let logo = providerLogo(for: item)
        var draw: [PixelClockDrawInstruction] = []
        for row in logo.pixels.indices {
            for column in logo.pixels[row].indices {
                guard let color = logo.colorHex(row: row, column: column) else { continue }
                draw.append(.pixel(x: column, y: row, color: tint ?? color))
            }
        }
        return draw
    }

    /// Draws the provider logo recolored against the pride flag, preserving
    /// each logo's internal color zones so the shape stays recognizable.
    ///
    /// Strategy: every logo has 1-4 distinct color zones (Claude: shell vs.
    /// eyes; Codex: body vs. white slash vs. dark base; MiniMax: outer vs.
    /// inner ribbons; …). For each provider we hand-craft a zone→flag-index
    /// map so the most prominent zone gets one pride color and the secondary
    /// zones get a contrasting pride color that stays consistent with the
    /// page accent. The page index rotates the mapping so the matrix sweeps
    /// through the pride flag while shapes stay sharp.
    private static func rainbowLogoDraw(
        for item: PixelClockQuotaItem,
        pageIndex: Int
    ) -> [PixelClockDrawInstruction] {
        let token = "\(item.providerID) \(item.providerName)".lowercased()
        let logo = providerLogo(for: item)
        let flag = PixelClockPalette.rainbowFlag
        let baseIndex = ((pageIndex % flag.count) + flag.count) % flag.count

        // Per-provider color zone → flag-index offset map. Offsets are
        // _added_ to baseIndex so the whole logo shifts hue per page.
        let zoneMap: [String: Int] = rainbowZoneOffsets(for: token)

        var draw: [PixelClockDrawInstruction] = []
        for row in logo.pixels.indices {
            for column in logo.pixels[row].indices {
                guard let originalHex = logo.colorHex(row: row, column: column) else { continue }
                let offset = zoneMap[originalHex.uppercased()] ?? 0
                let flagIndex = ((baseIndex + offset) % flag.count + flag.count) % flag.count
                draw.append(.pixel(x: column, y: row, color: flag[flagIndex]))
            }
        }
        // Synthetic detail overlays: a few logos (Z.ai, Factory, Codex)
        // collapse into one or two color zones when remapped, so we
        // overlay a small contrasting accent that keeps the silhouette
        // recognizable on the matrix.
        draw.append(contentsOf: rainbowAccentOverlay(for: token, pageIndex: pageIndex))
        return draw
    }

    /// Tiny per-provider accent pixels that ride on top of the rainbow logo
    /// so its iconic silhouette stays legible even when every zone is
    /// mapped to a single flag color.
    private static func rainbowAccentOverlay(
        for token: String,
        pageIndex: Int
    ) -> [PixelClockDrawInstruction] {
        let flag = PixelClockPalette.rainbowFlag
        let baseIndex = ((pageIndex % flag.count) + flag.count) % flag.count
        // Highlight color = farthest pride color from the base (3 hops).
        let highlight = flag[(baseIndex + 3) % flag.count]
        let shadow = flag[(baseIndex + 2) % flag.count]
        let sparkle = flag[(baseIndex + 5) % flag.count]

        if token.contains("claude") {
            // Two eye dots stay distinct against the body — already
            // handled by zone map (offset 3). Add two sparkle pixels
            // at the antennae tips for extra crab personality.
            return [
                .pixel(x: 0, y: 5, color: sparkle),
                .pixel(x: 7, y: 5, color: sparkle)
            ]
        }
        if token.contains("codex") || token.contains("openai") {
            // Trace the diagonal slash with sparkle so the staircase
            // reads even with body fully rainbow.
            return [
                .pixel(x: 2, y: 5, color: sparkle),
                .pixel(x: 3, y: 4, color: sparkle),
                .pixel(x: 5, y: 5, color: sparkle),
                .pixel(x: 6, y: 5, color: sparkle)
            ]
        }
        if token.contains("minimax") {
            // Highlight the two weave crossings on rows 2 and 5.
            return [
                .pixel(x: 3, y: 2, color: highlight),
                .pixel(x: 4, y: 2, color: highlight),
                .pixel(x: 3, y: 5, color: highlight),
                .pixel(x: 4, y: 5, color: highlight)
            ]
        }
        if token.contains("z.ai") || token.contains("zai") {
            // Re-draw the diagonal so the Z still reads even when
            // top/bottom slabs are remapped to the same flag color.
            return [
                .pixel(x: 6, y: 2, color: shadow),
                .pixel(x: 5, y: 3, color: shadow),
                .pixel(x: 4, y: 4, color: shadow),
                .pixel(x: 3, y: 5, color: shadow),
                .pixel(x: 2, y: 6, color: shadow)
            ]
        }
        if token.contains("factory") || token.contains("droid") {
            // 2×2 grey hub from the original logo — keep it contrasting.
            return [
                .pixel(x: 3, y: 3, color: shadow),
                .pixel(x: 4, y: 3, color: shadow),
                .pixel(x: 3, y: 4, color: shadow),
                .pixel(x: 4, y: 4, color: shadow)
            ]
        }
        if token.contains("ollama") {
            // Two eye dots on row 3 — already in zone map, but pin them
            // explicitly so they pop on every page.
            return [
                .pixel(x: 2, y: 3, color: sparkle),
                .pixel(x: 5, y: 3, color: sparkle)
            ]
        }
        if token.contains("cursor") {
            // Cube edge — keep the inverted corner sparkling.
            return [
                .pixel(x: 1, y: 4, color: sparkle),
                .pixel(x: 1, y: 5, color: sparkle),
                .pixel(x: 2, y: 5, color: sparkle)
            ]
        }
        if token.contains("warp") {
            // Center vortex — two dark pixels.
            return [
                .pixel(x: 3, y: 4, color: shadow),
                .pixel(x: 4, y: 4, color: shadow)
            ]
        }
        if token.contains("kimi") {
            // Eye dot.
            return [
                .pixel(x: 5, y: 2, color: sparkle)
            ]
        }
        if token.contains("copilot") {
            // GitHub-style "ribbon" pop — bright pixel in the middle.
            return [
                .pixel(x: 4, y: 4, color: sparkle)
            ]
        }
        return []
    }

    /// Public helper for previews — returns the resolved hex remap
    /// for a given provider/page so the SwiftUI preview matches the
    /// device-side rainbow rendering pixel-for-pixel.
    public static func rainbowZoneRemap(
        for item: PixelClockQuotaItem,
        pageIndex: Int
    ) -> [String: String] {
        let token = "\(item.providerID) \(item.providerName)".lowercased()
        let flag = PixelClockPalette.rainbowFlag
        let baseIndex = ((pageIndex % flag.count) + flag.count) % flag.count
        let zoneMap = rainbowZoneOffsets(for: token)
        var resolved: [String: String] = [:]
        for (originalHex, offset) in zoneMap {
            let flagIndex = ((baseIndex + offset) % flag.count + flag.count) % flag.count
            resolved[originalHex.uppercased()] = flag[flagIndex]
        }
        // Fallback for any logo color not explicitly mapped — uses the
        // base page color so all pixels still receive a pride hue.
        return resolved
    }

    /// Convenience used by the preview painter — returns the page accent
    /// color so unmapped logo pixels still get a pride hue.
    public static func rainbowPageAccent(at pageIndex: Int) -> String {
        PixelClockPalette.rainbow.rainbowColor(at: pageIndex)
    }

    /// Hand-tuned per-provider zone→flag-offset map. Distinct logo colors
    /// land on _different_ pride colors so shapes stay readable.
    /// Offsets are chosen to maximize contrast on the flag's hue wheel:
    /// 0 (red) ↔ 3 (green), 1 (orange) ↔ 4 (blue), 2 (yellow) ↔ 5 (violet).
    private static func rainbowZoneOffsets(for token: String) -> [String: Int] {
        // Claude — coral shell vs. dark eyes (preserve eye holes).
        if token.contains("claude") {
            return ["#D97757": 0, "#1A1208": 3]
        }
        // Codex — light blue body, white slashes, deep blue base.
        if token.contains("codex") || token.contains("openai") {
            return ["#8EA0FF": 0, "#FFFFFF": 2, "#4258FF": 4]
        }
        // MiniMax — outer magenta ribbon vs. inner coral weave.
        if token.contains("minimax") {
            return ["#EC1970": 0, "#FF5B3F": 3]
        }
        // Z.ai — top/bottom slabs (white) vs. middle slabs (lavender).
        if token.contains("z.ai") || token.contains("zai") {
            return ["#FFFFFF": 0, "#C9B6FF": 3]
        }
        // Factory — sunburst petals (white) vs. grey core hub.
        if token.contains("factory") || token.contains("droid") {
            return ["#FFFFFF": 0, "#B8B8B8": 3]
        }
        // Copilot — multi-hue swirl built from blue, teal, green, yellow,
        // orange, magenta bands. Map each natural hue family to its own
        // pride color so the swirl reads as a full spectrum.
        if token.contains("copilot") {
            return [
                "#0F4E70": 4, "#1A80B6": 4, "#187DB4": 4, "#1050A2": 4,
                "#05293E": 4, "#091F60": 4, "#118BD1": 4, "#1397E1": 4,
                "#148FDD": 4, "#1558D0": 4, "#1652BA": 4, "#031121": 4,
                "#1B656E": 3, "#2BA1AF": 3, "#2EA3A9": 3, "#257F90": 3,
                "#529F62": 3, "#60B46C": 3, "#66B666": 3, "#305A32": 3,
                "#A5BB36": 2, "#AFC033": 2, "#ABB92D": 2, "#2A310B": 2,
                "#6C610A": 2, "#AC8D13": 2, "#D19422": 2,
                "#D26238": 1, "#F36544": 1, "#F88D61": 1, "#F9886D": 1,
                "#E6756A": 1, "#75341D": 1, "#762D45": 1, "#CD5E5E": 1,
                "#F46A80": 0, "#F16187": 0, "#963B57": 0,
                "#67251B": 5, "#B05634": 5, "#BA7B40": 5, "#BA7445": 5,
                "#72442D": 5, "#172C62": 5, "#675CBC": 5, "#7350AF": 5,
                "#572E73": 5, "#381429": 5, "#452121": 5,
                "#C64FAF": 5, "#BB51CC": 5, "#B24FCB": 5, "#E55898": 5,
                "#D954A7": 5, "#BC4A97": 5
            ]
        }
        // Cursor — cube is built from highlights, midtones, dark face,
        // and pure black edge. Split into 4 luminance bands.
        if token.contains("cursor") {
            return [
                "#FFFFFF": 0, "#F9F9F9": 0, "#FAFAFA": 0, "#FCFCFC": 0,
                "#DDDDDD": 1, "#DEDEDE": 1, "#D2D2D2": 1, "#CFCFCF": 1,
                "#D0D0D0": 1, "#D8D8D8": 1, "#DADADA": 1, "#D9D9D9": 1,
                "#E6E6E6": 1, "#CBCBCB": 1,
                "#B3B3B3": 2, "#B2B2B2": 2, "#B0B0B0": 2, "#B9B9B9": 2,
                "#ABABAB": 2, "#8D8D8D": 2,
                "#7D7D7D": 3, "#7C7C7C": 3, "#797979": 3, "#5B5B5B": 3,
                "#787878": 3, "#727272": 3, "#6C6C6C": 3, "#6A6A6A": 3,
                "#6B6B6B": 3, "#565656": 3,
                "#333333": 4, "#464646": 4, "#5A5A5A": 4, "#3C3C3C": 4,
                "#252525": 4, "#232323": 4, "#242424": 4, "#212121": 4,
                "#1F1F1F": 4, "#1E1E1E": 4, "#171717": 4,
                "#0F0F0F": 5, "#101010": 5, "#030303": 5, "#000000": 5
            ]
        }
        // Warp — vortex needs three luminance bands (light gloss / midtone
        // ring / dark core) mapped to three different pride colors so the
        // circular silhouette stays readable.
        if token.contains("warp") {
            return [
                "#FFFFFF": 0, "#FBFBFB": 0, "#FCFCFC": 0, "#FAFAFA": 0,
                "#F4F5F6": 1, "#F5F6F7": 1, "#F5F7F7": 1, "#F6F7F8": 1,
                "#F6F8F8": 1, "#FCFCFD": 1, "#FBFCFC": 1, "#F3F5F5": 1,
                "#DCE0E3": 2, "#D0D6DA": 2, "#CFD5D9": 2, "#D2D8DC": 2,
                "#D4DADE": 2, "#D6DCE0": 2, "#D8DEE2": 2, "#CCD2D6": 2,
                "#E1E6E9": 2, "#E3E8EB": 2,
                "#ADB2B6": 3, "#A1A6AA": 3, "#ACB1B4": 3, "#B3B8BC": 3,
                "#B2B7BB": 3, "#B4B9BD": 3, "#C1C6CA": 3, "#C4C9CD": 3,
                "#6E7173": 4, "#777A7C": 4, "#787B7D": 4, "#8C8F92": 4,
                "#3B3C3D": 5, "#47494A": 5, "#373838": 5, "#313233": 5,
                "#4B4C4D": 5, "#323333": 5, "#494A4B": 5, "#282828": 5
            ]
        }
        // Ollama — alpaca body (creamy white) vs. blue eyes vs. grey feet.
        if token.contains("ollama") {
            return [
                "#F6F8FF": 0, "#FAFCFF": 0,
                "#1EA7FF": 2, "#0098EE": 2,
                "#AEB7C2": 4, "#BEC7D2": 4
            ]
        }
        // Kimi — dark body vs. light fur highlights vs. blue accent.
        // Split fur greys into two bands so the silhouette has internal
        // contrast.
        if token.contains("kimi") {
            return [
                "#252525": 0, "#2F2F2F": 0, "#2D2D2D": 0,
                "#242424": 1, "#232323": 1, "#1A1A1A": 1,
                "#303030": 1, "#313131": 1, "#343434": 1,
                "#404040": 1, "#0F1C2B": 1, "#0A2E57": 1,
                "#828282": 2, "#858585": 2, "#7C7C7C": 2,
                "#6F6F6F": 2, "#8B8B8B": 2, "#8D8D8D": 2,
                "#919191": 2, "#B2B2B2": 2, "#B8B8B8": 2,
                "#C2C2C2": 3, "#CDCDCD": 3, "#C3C3C3": 3,
                "#C9C9C9": 3, "#D3D3D3": 3, "#D7D7D7": 3,
                "#DDDDDD": 3, "#DFDFDF": 3,
                "#052040": 5, "#136CD2": 5
            ]
        }
        return [:]
    }

    static func providerLogoPattern(for item: PixelClockQuotaItem) -> [String] {
        providerLogo(for: item).rows
    }

    static func providerLogo(for item: PixelClockQuotaItem) -> PixelClockProviderLogo {
        let token = "\(item.providerID) \(item.providerName)".lowercased()
        if token.contains("claude") {
            return PixelClockProviderLogoAssets.claudeCode
        }
        if token.contains("codex") {
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
            let colorKey = index == 0 ? "1" : "2"
            for (row, bits) in glyph.enumerated() {
                for (column, bit) in bits.enumerated() where bit == 1 {
                    rows[row + 1][x + column] = colorKey
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
            normalized.contains(item.providerID.lowercased()) || item.agentStatus == .running
        }
    }

    /// Returns the provider items in display order: filtered to the selected
    /// `providerIDs`, then rotated so `selectedProviderIndex` is the first
    /// page. The rotation lets hardware-button input on the device move the
    /// active page without changing the underlying provider list.
    public static func selectedItems(
        items: [PixelClockQuotaItem],
        config: PixelClockConfig
    ) -> [PixelClockQuotaItem] {
        let filtered = filteredItems(items, providerIDs: config.providerIDs)
        guard filtered.count > 1 else { return filtered }
        let count = filtered.count
        let offset = positiveModulo(config.selectedProviderIndex, count)
        guard offset != 0 else { return filtered }
        return Array(filtered[offset..<count]) + Array(filtered[0..<offset])
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

// MARK: - Helpers

/// Modulo that always returns a non-negative result, so it can be used to
/// index into wraparound rings even when the caller passes a negative tick.
fileprivate func positiveModulo(_ lhs: Int, _ rhs: Int) -> Int {
    guard rhs != 0 else { return 0 }
    let r = lhs % rhs
    return r >= 0 ? r : r + abs(rhs)
}
