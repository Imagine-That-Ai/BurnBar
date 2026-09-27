import Foundation

/// The slice of settings the usage-memory consent flow and local-model setup
/// wizard read and write. `SettingsManager` conforms (SettingsManager+Memory);
/// the U2/U3 surfaces depend on this contract instead of the settings root so
/// they stay off the app-wide dependency cycle
/// (docs/SERVICES_DECOMPOSITION_PROGRAM.md, remedy 4).
@MainActor
protocol UsageMemorySettingsProviding: AnyObject {
    /// Where the usage-memory curation model runs.
    var usageMemoryModelPlacement: UsageMemoryModelPlacement { get set }
    /// Separate, affirmative opt-in to cloud curation.
    var usageMemoryCloudCurationConsentGranted: Bool { get set }
    /// Source toggle: Safari asks feed usage memory.
    var usageMemorySourceSafariAsksEnabled: Bool { get set }
    /// Source toggle: recorded agent sessions feed usage memory.
    var usageMemorySourceAgentSessionsEnabled: Bool { get set }
    /// Base URL of the local (Ollama) model server; empty means the default.
    var summaryLocalBaseURL: String { get }
    /// Local curation text model; empty means the shipped default.
    var summaryLocalModel: String { get }
    /// Optional local vision model; empty means images are skipped locally.
    var usageMemoryLocalVLModel: String { get }
}
