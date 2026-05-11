import Foundation

// MARK: - Smart Display Config Codec
//
// Shared Firestore (de)serialization for `SmartHubDisplayConfig` and the
// `SmartDisplayOrder`. Both Mac and iOS bridge through Firestore with
// `[String: Any]` payloads, so we keep a single source of truth that
// mirrors the schema-v3 documents both clients agree on.

public enum SmartDisplayConfigCodec {

    public static func encode(_ config: SmartHubDisplayConfig) -> [String: Any] {
        [
            "layout": config.layout.rawValue,
            "palette": config.palette.rawValue,
            "theme": config.theme.rawValue,
            "background": config.background.rawValue,
            "brightness": config.clampedBrightness,
            "scrollSpeedSeconds": config.clampedScrollSpeed,
            "refreshCadenceSeconds": config.clampedRefreshCadence,
            "providerIDs": config.providerIDs,
            "audibleCue": config.audibleCue,
            "identifyOnRefresh": config.identifyOnRefresh,
            "updatedAt": ISO8601DateFormatter().string(from: config.updatedAt)
        ]
    }

    public static func decode(_ data: [String: Any]?) -> SmartHubDisplayConfig? {
        guard let data else { return nil }
        let updatedAt: Date = {
            if let raw = data["updatedAt"] as? String,
               let parsed = ISO8601DateFormatter().date(from: raw) {
                return parsed
            }
            return Date()
        }()
        return SmartHubDisplayConfig(
            layout: (data["layout"] as? String).flatMap(SmartHubDisplayLayout.init(rawValue:)) ?? .quotaCarousel,
            palette: (data["palette"] as? String).flatMap(SmartHubDisplayPalette.init(rawValue:)) ?? .emberWhimsy,
            theme: (data["theme"] as? String).flatMap(SmartHubDisplayTheme.init(rawValue:)) ?? .warmCharcoal,
            background: (data["background"] as? String).flatMap(SmartHubDisplayBackground.init(rawValue:)) ?? .dashboard,
            brightness: doubleValue(data["brightness"]) ?? 0.85,
            scrollSpeedSeconds: intValue(data["scrollSpeedSeconds"]) ?? 8,
            refreshCadenceSeconds: intValue(data["refreshCadenceSeconds"]) ?? 5,
            providerIDs: (data["providerIDs"] as? [String]) ?? [],
            audibleCue: data["audibleCue"] as? Bool ?? false,
            identifyOnRefresh: data["identifyOnRefresh"] as? Bool ?? false,
            updatedAt: updatedAt
        )
    }

    public static func encodeOrder(_ order: SmartDisplayOrder) -> [String] {
        order.kinds.map(\.rawValue)
    }

    public static func decodeOrder(_ raw: [String]?) -> SmartDisplayOrder {
        guard let raw else { return .default }
        let kinds = raw.compactMap(SmartDisplayKind.init(rawValue:))
        return SmartDisplayOrder(kinds: kinds)
    }

    // MARK: - Number helpers (Firestore returns numbers as NSNumber)

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Float { return Double(v) }
        if let v = raw as? Int { return Double(v) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return Int(v) }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }
}
