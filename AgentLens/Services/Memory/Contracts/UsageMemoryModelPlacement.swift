import Foundation

/// Where the usage-memory curation model runs. Only the cloud placements can
/// ever satisfy `UsageMemoryCloudGate`; `.local` (the default) keeps the whole
/// pipeline on-device.
enum UsageMemoryModelPlacement: String, CaseIterable, Sendable {
    /// On-device model. Default: nothing usage-derived leaves the machine.
    case local
    /// A user-configured cloud text model.
    case cloudText
    /// The BurnBar-hosted cloud curation service.
    case burnbarCloud

    /// True for any placement that sends usage-derived material off-device.
    var isCloud: Bool { self != .local }
}
