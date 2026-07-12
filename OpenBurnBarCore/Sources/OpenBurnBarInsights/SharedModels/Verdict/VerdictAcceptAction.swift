import Foundation

/// A one-tap follow-through the user can trigger from a bullet or
/// recommendation.
///
/// Voice contract §3.8 — "every push is reciprocal." Every bullet that
/// makes a recommendation must carry an `acceptAction` so the user gains
/// agency from the surface, not just observation.
///
/// `intent` is a closed enum the post-processor validates; the renderer
/// dispatches by switching on it. `payload` carries the intent-specific
/// arguments and is opaque at the schema level (Codable via JSON).
public struct VerdictAcceptAction: Codable, Hashable, Sendable {

    /// Closed registry of action intents the renderer knows how to handle.
    /// New intents require a renderer update *and* a schema bump so older
    /// clients fall back to the no-action display gracefully.
    public enum Intent: String, Codable, Hashable, Sendable, CaseIterable {
        /// Mutate the router rule (e.g. "make Haiku default for short prompts").
        case switchRouterRule
        /// Pin the canvas authoring this bullet to the sidebar.
        case pinCanvas
        /// Open the specific session that originated this bullet.
        case openSession
        /// Open the relevant Settings pane.
        case openSettings
        /// Open an external URL (docs, dashboard).
        case openExternal
        /// Spawn a mission from the bullet's evidence.
        case createMission
        /// Refresh the brief with a deeper investigation.
        case investigate
        /// Mute or snooze a recurring recommendation.
        case snooze
    }

    /// Button label (≤28 chars, sentence case).
    public var label: String
    public var intent: Intent
    /// Intent-specific opaque payload, JSON-encoded as `Data` so it round-trips.
    public var payload: Data?

    public init(label: String, intent: Intent, payload: Data? = nil) {
        self.label = label
        self.intent = intent
        self.payload = payload
    }

    /// Convenience to attach a `[String: String]` payload without callers
    /// reaching for `JSONSerialization`.
    public init(label: String, intent: Intent, payloadDict: [String: String]) {
        self.label = label
        self.intent = intent
        self.payload = try? JSONSerialization.data(
            withJSONObject: payloadDict,
            options: [.sortedKeys]
        )
    }

    /// Decode the payload as a typed dictionary. Returns `nil` if absent
    /// or malformed.
    public func payloadDictionary() -> [String: String]? {
        guard let payload else { return nil }
        return try? JSONSerialization
            .jsonObject(with: payload, options: []) as? [String: String]
    }
}
