import Foundation

/// Who started a unit of work — the Command Board's STARTED BY column.
///
/// One typed shape stamped everywhere work begins (missions, runs, usage rows,
/// fleet rows, Flame decisions) so the board never guesses attribution. The
/// Firestore wire mirror is `OriginatorRef` in the `war-room` schema domain
/// (`tools/schema-sync/typespec/domains/war-room.tsp`); this type is the
/// registered Swift hand mirror.
public enum BurnBarOriginatorKind: String, Codable, CaseIterable, Sendable {
    case userLocal = "user_local"
    case userRemote = "user_remote"
    case flame
    case wand
    case mission
    case hermesBot = "hermes_bot"
    case hermesCron = "hermes_cron"
    case external
    case unknown
}

/// Fleet-style honesty vocabulary: external rows are usually `inferred`;
/// anything BurnBar dispatched itself is `exact`.
public enum BurnBarOriginatorConfidence: String, Codable, CaseIterable, Sendable {
    case exact
    case inferred
    case unknown
}

public struct BurnBarOriginator: Codable, Sendable, Equatable, Hashable {
    public var kind: BurnBarOriginatorKind
    public var label: String
    public var bodyID: String?
    public var decisionID: String?
    public var missionID: String?
    public var missionGroupID: String?
    public var botName: String?
    public var confidence: BurnBarOriginatorConfidence

    public init(
        kind: BurnBarOriginatorKind,
        label: String? = nil,
        bodyID: String? = nil,
        decisionID: String? = nil,
        missionID: String? = nil,
        missionGroupID: String? = nil,
        botName: String? = nil,
        confidence: BurnBarOriginatorConfidence
    ) {
        self.kind = kind
        self.bodyID = bodyID
        self.decisionID = decisionID
        self.missionID = missionID
        self.missionGroupID = missionGroupID
        self.botName = botName
        self.confidence = confidence
        self.label = label ?? Self.defaultLabel(
            kind: kind,
            decisionID: decisionID,
            missionID: missionID,
            missionGroupID: missionGroupID,
            botName: botName
        )
    }

    /// Render-ready default label per kind ("Flame · d-a3f2c9", "Wand · group 9c41f0e2", …).
    public static func defaultLabel(
        kind: BurnBarOriginatorKind,
        decisionID: String? = nil,
        missionID: String? = nil,
        missionGroupID: String? = nil,
        botName: String? = nil
    ) -> String {
        switch kind {
        case .userLocal:
            return "you (this Mac)"
        case .userRemote:
            return "you (remote)"
        case .flame:
            if let decisionID, !decisionID.isEmpty {
                return "Flame · \(shortRef(decisionID))"
            }
            return "Flame"
        case .wand:
            if let missionGroupID, !missionGroupID.isEmpty {
                return "Wand · group \(shortRef(missionGroupID))"
            }
            return "Wand"
        case .mission:
            if let missionID, !missionID.isEmpty {
                return "mission · \(shortRef(missionID))"
            }
            return "mission"
        case .hermesBot:
            if let botName, !botName.isEmpty {
                return "Hermes \(botName)"
            }
            return "Hermes bot"
        case .hermesCron:
            if let botName, !botName.isEmpty {
                return "Hermes \(botName) · cron"
            }
            return "Hermes cron"
        case .external:
            return "external"
        case .unknown:
            return "unknown"
        }
    }

    /// The single most specific reference — what the `originatorRef` SQLite
    /// column and deep links key on.
    public var primaryRef: String? {
        decisionID ?? missionGroupID ?? missionID ?? botName ?? bodyID
    }

    /// Canonical `external` attribution for sessions BurnBar can see but did
    /// not dispatch. Never guessed prettier than `inferred`.
    public static let externalInferred = BurnBarOriginator(
        kind: .external,
        confidence: .inferred
    )

    public static let unknown = BurnBarOriginator(
        kind: .unknown,
        confidence: .unknown
    )

    private static func shortRef(_ ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        return String(trimmed.prefix(8))
    }
}

// MARK: - Flat wire codec (mission docs, SQLite columns)

public extension BurnBarOriginator {
    /// Flat two-field form for surfaces that cannot carry a nested map:
    /// `originatorKind` + `originatorRef` (token_usage columns, mission docs).
    var flatFields: (kind: String, ref: String?) {
        (kind.rawValue, primaryRef)
    }

    /// Rebuild from the flat two-field form. The specific-ref slot is chosen
    /// by kind so `primaryRef` round-trips.
    init?(flatKind: String?, flatRef: String?) {
        guard let flatKind, let kind = BurnBarOriginatorKind(rawValue: flatKind) else {
            return nil
        }
        let ref = flatRef?.isEmpty == true ? nil : flatRef
        switch kind {
        case .flame:
            self.init(kind: kind, decisionID: ref, confidence: .exact)
        case .wand:
            self.init(kind: kind, missionGroupID: ref, confidence: .exact)
        case .mission:
            self.init(kind: kind, missionID: ref, confidence: .exact)
        case .hermesBot, .hermesCron:
            self.init(kind: kind, botName: ref, confidence: .inferred)
        case .userLocal, .userRemote:
            self.init(kind: kind, bodyID: ref, confidence: .exact)
        case .external:
            self.init(kind: kind, bodyID: ref, confidence: .inferred)
        case .unknown:
            self.init(kind: kind, confidence: .unknown)
        }
    }

    /// Full-map form for Firestore payloads that can carry the nested shape
    /// (`OriginatorRef` wire mirror). String values only — safe to splat into
    /// `[String: Any]` document payloads.
    var wireDictionary: [String: String] {
        var fields: [String: String] = [
            "kind": kind.rawValue,
            "label": label,
            "confidence": confidence.rawValue
        ]
        if let bodyID { fields["bodyID"] = bodyID }
        if let decisionID { fields["decisionID"] = decisionID }
        if let missionID { fields["missionID"] = missionID }
        if let missionGroupID { fields["missionGroupID"] = missionGroupID }
        if let botName { fields["botName"] = botName }
        return fields
    }

    init?(wireDictionary raw: [String: Any]) {
        guard
            let kindRaw = raw["kind"] as? String,
            let kind = BurnBarOriginatorKind(rawValue: kindRaw)
        else { return nil }
        let confidence = (raw["confidence"] as? String)
            .flatMap(BurnBarOriginatorConfidence.init(rawValue:)) ?? .unknown
        self.init(
            kind: kind,
            label: raw["label"] as? String,
            bodyID: raw["bodyID"] as? String,
            decisionID: raw["decisionID"] as? String,
            missionID: raw["missionID"] as? String,
            missionGroupID: raw["missionGroupID"] as? String,
            botName: raw["botName"] as? String,
            confidence: confidence
        )
    }
}
