import Foundation

/// Fleet configuration resolved from the environment.
///
/// Seams (required by the validation contract):
/// - `BURNBAR_FLEET_CADENCE_SECONDS` — snapshot cadence override (default 15).
///   The value is clamped to a sane minimum (1 second) so hermetic validators
///   can observe ticks quickly; it is reflected verbatim in every snapshot's
///   `cadenceSeconds` and in the well-known file.
/// - `BURNBAR_FLEET_ROOTS_DIR` / per-probe overrides — probe-root override
///   seam (see `BurnBarFleetRootResolver`).
public struct BurnBarFleetConfiguration: Sendable {
    public static let defaultCadenceSeconds = BurnBarFleetCadencePolicy.defaultCadenceSeconds
    public static let minimumCadenceSeconds = 1

    public let cadenceSeconds: Int
    public let rootResolver: BurnBarFleetRootResolver

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rootResolver: BurnBarFleetRootResolver? = nil
    ) {
        let rawCadence = environment["BURNBAR_FLEET_CADENCE_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawCadence, let parsed = Int(rawCadence), parsed >= BurnBarFleetConfiguration.minimumCadenceSeconds {
            self.cadenceSeconds = parsed
        } else {
            self.cadenceSeconds = BurnBarFleetConfiguration.defaultCadenceSeconds
        }
        self.rootResolver = rootResolver ?? BurnBarFleetRootResolver(environment: environment)
    }
}
