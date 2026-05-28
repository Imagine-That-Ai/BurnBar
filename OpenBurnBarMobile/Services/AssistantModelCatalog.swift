import Foundation
import OpenBurnBarCore

// MARK: - Assistant Model Catalog
//
// EVERY harness in OpenBurnBar is an *agent harness* that routes prompts
// to a real frontier LLM or a local CLI agent. Hermes and Pi expose the
// live relay-advertised model list. Codex, Claude Code, Droid, and Forge
// expose CLI-native catalogs so the picker never offers a model the
// underlying binary cannot serve.
//
// The relay model list is **not** hardcoded into mobile. The source of
// truth lives in `website/scripts/rundown-seed/models.json` — the same
// file the router rundown pages read so the website and the app stay
// in lockstep. A trimmed copy is bundled at
// `OpenBurnBarMobile/Resources/openburnbar_models.json` so the catalog
// is always available offline. Online, callers can override the bundled
// copy by calling `AssistantModelCatalog.refreshRemote(...)` — that hits
// the website-hosted JSON, parses it, and replaces the in-memory list.
//
// CLI model lists are fetched from the paired Mac at picker/send time via
// `HermesService.fetchCLIRuntimeModelCatalog`. `CLIRuntimeModelCatalog` only
// carries the wire shape and parsers; it is not a bundled source of truth.

/// One row in the catalog. Mirrors `HermesRuntimeModelOption` in shape so
/// the same UI rows can render either source.
public struct AssistantModelOption: Hashable, Identifiable, Sendable {
    public var id: String { providerID + ":" + modelID }
    public let providerID: String
    public let providerName: String
    public let modelID: String
    public let displayName: String
    public let tier: String
    public let cliSource: CLIRuntimeModelSource?

    public init(providerID: String,
                providerName: String,
                modelID: String,
                displayName: String,
                tier: String = "mid",
                cliSource: CLIRuntimeModelSource? = nil) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.displayName = displayName
        self.tier = tier
        self.cliSource = cliSource
    }

    public init(cliOption: CLIRuntimeModelOption) {
        self.init(
            providerID: cliOption.providerID,
            providerName: cliOption.providerName,
            modelID: cliOption.modelID,
            displayName: cliOption.displayName,
            tier: cliOption.tier,
            cliSource: cliOption.source
        )
    }
}

// MARK: - Model ID aliases

/// Shared model-ID compatibility layer for mobile preferences and live relay
/// catalogs. The public website catalog historically used URL-safe marketing
/// slugs (`minimax-m2-7`, `gpt-5-4-mini`) while real OpenAI-compatible
/// gateways advertise provider-native IDs (`minimax-m2.7-highspeed`,
/// `gpt-5.4-mini`). Persist and send the provider-native ID whenever the live
/// relay can prove it exists.
enum AssistantModelIDCanonicalizer {
    static func canonicalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "gpt-5-5":
            return "gpt-5.5"
        case "gpt-5-4":
            return "gpt-5.4"
        case "gpt-5-4-mini":
            return "gpt-5.4-mini"
        case "gpt-5-3-codex":
            return "gpt-5.3-codex"
        case "minimax-m2-7":
            return "minimax-m2.7-highspeed"
        case "kimi-k2-6":
            return "kimi-k2.6"
        case "kimi-k2-5":
            return "kimi-k2.5"
        case "glm-5":
            return "glm-5-turbo"
        default:
            return trimmed
        }
    }

    static func canonicalizedPersistedSelection(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "gpt-5-5", "gpt-5-4", "gpt-5-4-mini", "gpt-5-3-codex", "minimax-m2-7", "kimi-k2-6", "kimi-k2-5":
            return canonicalized(trimmed)
        default:
            return trimmed
        }
    }

    static func lookupKey(_ raw: String) -> String {
        canonicalized(raw)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func familyKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func resolveRouteEligibleModelID(
        _ raw: String,
        in options: [HermesRuntimeModelOption]
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let eligible = options.filter(\.isRouteEligible)
        if let exact = eligible.first(where: { $0.modelID == trimmed }) {
            return exact.modelID
        }
        if let caseInsensitive = eligible.first(where: { $0.modelID.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return caseInsensitive.modelID
        }

        let canonical = canonicalized(trimmed)
        if canonical != trimmed {
            if let exactCanonical = eligible.first(where: { $0.modelID == canonical }) {
                return exactCanonical.modelID
            }
            if let caseInsensitiveCanonical = eligible.first(where: { $0.modelID.caseInsensitiveCompare(canonical) == .orderedSame }) {
                return caseInsensitiveCanonical.modelID
            }
        }

        let rawFamilyKey = familyKey(trimmed)
        return eligible.first { familyKey($0.modelID) == rawFamilyKey }?.modelID
    }
}

// MARK: - Catalog store

public actor AssistantModelCatalogStore {
    public static let shared = AssistantModelCatalogStore()

    private var cached: [AssistantModelOption]?

    private init() {}

    /// Return the current catalog. First call loads from the bundle; later
    /// calls return the cached copy until `refreshFromBundle` or
    /// `refreshRemote` swaps it.
    public func options() -> [AssistantModelOption] {
        if let cached { return cached }
        let loaded = Self.loadFromBundle() ?? []
        cached = loaded
        return loaded
    }

    /// Re-read the bundled JSON. Useful if a future setting lets the user
    /// switch back to "shipped catalog only".
    public func refreshFromBundle() {
        cached = Self.loadFromBundle() ?? []
    }

    /// Fetch the latest catalog from the website-hosted JSON and replace
    /// the cache. Silently falls back to the bundled copy on any error so
    /// the app never shows an empty picker.
    public func refreshRemote(from url: URL = AssistantModelCatalog.remoteCatalogURL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let parsed = try Self.decode(data)
            if !parsed.isEmpty {
                cached = parsed
            }
        } catch {
            // Network failure is fine — keep whatever's cached.
        }
    }

    // MARK: - Decoder

    private static func loadFromBundle() -> [AssistantModelOption]? {
        guard let url = Bundle.main.url(forResource: "openburnbar_models", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? decode(data)
    }

    private static func decode(_ data: Data) throws -> [AssistantModelOption] {
        let raw = try JSONDecoder().decode([RawEntry].self, from: data)
        return raw.map { entry in
            let canonicalModelID = AssistantModelIDCanonicalizer.canonicalized(entry.modelID)
            return AssistantModelOption(
                providerID: entry.providerID,
                providerName: entry.providerDisplay,
                modelID: canonicalModelID,
                displayName: entry.modelDisplay,
                tier: entry.tier ?? "mid"
            )
        }
    }

    private struct RawEntry: Decodable {
        let modelID: String
        let modelDisplay: String
        let providerID: String
        let providerDisplay: String
        let tier: String?
    }
}

// MARK: - Public façade

public enum AssistantModelCatalog {

    /// Where to fetch the live catalog from. Points at the website's
    /// public JSON so we can drop new models in via a content push
    /// without an app release.
    public static let remoteCatalogURL: URL = URL(string: "https://burnbar.ai/data/models.json")!

    /// Synchronous access used by the picker. Returns whatever's currently
    /// cached in `AssistantModelCatalogStore`. The first call from any
    /// thread triggers a bundle load.
    public static func options(for runtime: AssistantRuntimeID) -> [AssistantModelOption] {
        if runtime.usesDynamicMacCLICatalog {
            return []
        }
        if runtime == .openClaw {
            return []
        }
        return Self.cachedOptions()
    }

    public static func defaultOption(for runtime: AssistantRuntimeID) -> AssistantModelOption? {
        options(for: runtime).first
    }

    public static func option(forModelID modelID: String,
                              in runtime: AssistantRuntimeID) -> AssistantModelOption? {
        options(for: runtime).first { $0.modelID == modelID }
    }

    /// CLI harnesses where the iOS-side preference is honored "on the next
    /// session" rather than instantly applied. Surfaced in the picker copy.
    public static func appliesNextSession(_ runtime: AssistantRuntimeID) -> Bool {
        switch runtime {
        case .hermes, .pi: return false
        case .codex, .claude, .openClaw, .droid, .forge, .antigravity, .grok: return true
        }
    }

    /// Kick off a remote refresh. Safe to call from `.task` modifiers.
    public static func refreshRemote() {
        Task.detached {
            await AssistantModelCatalogStore.shared.refreshRemote()
        }
    }

    // MARK: - Internal sync cache
    //
    // SwiftUI views need synchronous access. We mirror the actor's cache
    // into a `nonisolated(unsafe)` snapshot — readers always see the
    // last value, writers happen on the actor.

    nonisolated(unsafe) private static var snapshot: [AssistantModelOption] = []
    private static let snapshotLock = NSLock()

    fileprivate static func cachedOptions() -> [AssistantModelOption] {
        snapshotLock.lock()
        let current = snapshot
        snapshotLock.unlock()
        if !current.isEmpty { return current }
        // First read — synchronously load from the bundle so the UI never
        // starts with an empty picker.
        let loaded = AssistantModelCatalogStore.loadFromBundleSync() ?? []
        snapshotLock.lock()
        snapshot = loaded
        snapshotLock.unlock()
        return loaded
    }

    fileprivate static func updateSnapshot(_ value: [AssistantModelOption]) {
        snapshotLock.lock()
        snapshot = value
        snapshotLock.unlock()
    }
}

// MARK: - Bridge: actor cache → sync snapshot

extension AssistantModelCatalogStore {
    /// Synchronous bundle loader exposed to the public facade. Same
    /// underlying decoder as the actor-isolated path.
    fileprivate static func loadFromBundleSync() -> [AssistantModelOption]? {
        guard let url = Bundle.main.url(forResource: "openburnbar_models", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? decode(data)
    }
}

// MARK: - Preferences

/// Persistent storage for the user's preferred model for runtimes that
/// don't broadcast a live model list. Keyed per-runtime so a fresh install
/// can fall back to a sensible default without forgetting prior choices.
public enum CLIAgentModelPreferences {
    private static func key(for runtime: AssistantRuntimeID) -> String {
        "assistants.preferredModelID.\(runtime.rawValue)"
    }

    public static func preferredModelID(for runtime: AssistantRuntimeID,
                                        defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.string(forKey: key(for: runtime)) else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if runtime.usesDynamicMacCLICatalog {
            if trimmed != stored {
                defaults.set(trimmed, forKey: key(for: runtime))
            }
            return trimmed
        }
        let canonical = AssistantModelIDCanonicalizer.canonicalized(trimmed)
        if canonical != stored {
            defaults.set(canonical, forKey: key(for: runtime))
        }
        return canonical
    }

    public static func setPreferredModelID(_ modelID: String?,
                                           for runtime: AssistantRuntimeID,
                                           defaults: UserDefaults = .standard) {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let stored = runtime.usesDynamicMacCLICatalog
                ? trimmed
                : AssistantModelIDCanonicalizer.canonicalized(trimmed)
            defaults.set(stored, forKey: key(for: runtime))
        } else {
            defaults.removeObject(forKey: key(for: runtime))
        }
    }

    public static func preferredOption(for runtime: AssistantRuntimeID,
                                       defaults: UserDefaults = .standard) -> AssistantModelOption? {
        if runtime.usesDynamicMacCLICatalog {
            return nil
        }
        let options = AssistantModelCatalog.options(for: runtime)
        guard let preferredID = preferredModelID(for: runtime, defaults: defaults) else {
            return options.first
        }
        if let match = options.first(where: {
            AssistantModelIDCanonicalizer.lookupKey($0.modelID) == AssistantModelIDCanonicalizer.lookupKey(preferredID)
        }) {
            return match
        }
        return nil
    }

    public static func validatedPreferredModelID(
        for runtime: AssistantRuntimeID,
        defaults: UserDefaults = .standard,
        options explicitOptions: [AssistantModelOption]? = nil
    ) throws -> String? {
        guard let preferredID = preferredModelID(for: runtime, defaults: defaults)?.nonEmpty else {
            return nil
        }
        if runtime.usesDynamicMacCLICatalog {
            let options = explicitOptions ?? []
            guard !options.isEmpty else {
                throw CLIAgentModelPreferenceError.catalogUnverified(runtime: runtime, modelID: preferredID)
            }
            if let exact = options.first(where: {
                $0.modelID.caseInsensitiveCompare(preferredID) == .orderedSame
            }) {
                if exact.modelID != preferredID {
                    defaults.set(exact.modelID, forKey: key(for: runtime))
                }
                return exact.modelID
            }
            if let migrated = options.first(where: {
                AssistantModelIDCanonicalizer.lookupKey($0.modelID) == AssistantModelIDCanonicalizer.lookupKey(preferredID)
            }) {
                defaults.set(migrated.modelID, forKey: key(for: runtime))
                return migrated.modelID
            }
            throw CLIAgentModelPreferenceError.selectedModelUnavailable(runtime: runtime, modelID: preferredID)
        }
        let options = explicitOptions ?? AssistantModelCatalog.options(for: runtime)
        guard !options.isEmpty else {
            throw CLIAgentModelPreferenceError.catalogUnverified(runtime: runtime, modelID: preferredID)
        }
        guard options.contains(where: {
            AssistantModelIDCanonicalizer.lookupKey($0.modelID) == AssistantModelIDCanonicalizer.lookupKey(preferredID)
        }) else {
            throw CLIAgentModelPreferenceError.selectedModelUnavailable(runtime: runtime, modelID: preferredID)
        }
        return preferredID
    }
}

private extension AssistantRuntimeID {
    var usesDynamicMacCLICatalog: Bool {
        switch self {
        case .codex, .claude, .droid, .forge, .antigravity, .grok:
            return true
        case .hermes, .pi, .openClaw:
            return false
        }
    }
}

public enum CLIAgentModelPreferenceError: LocalizedError, Equatable {
    case catalogUnverified(runtime: AssistantRuntimeID, modelID: String)
    case selectedModelUnavailable(runtime: AssistantRuntimeID, modelID: String)

    public var errorDescription: String? {
        switch self {
        case let .catalogUnverified(runtime, modelID):
            return "Selected \(runtime.displayName) model '\(modelID)' has not been verified against this Mac \(runtime.displayName) harness catalog yet. Refresh the Mac \(runtime.displayName) gateway before sending, so the selected model is not silently rerouted."
        case let .selectedModelUnavailable(runtime, modelID):
            return "Selected \(runtime.displayName) model '\(modelID)' is no longer advertised by this Mac \(runtime.displayName) harness catalog. Pick an available model before sending, so the request is not silently rerouted."
        }
    }
}
