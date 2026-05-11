import Foundation

// MARK: - Pi Agent Command Profile

/// Centralized Pi CLI argument shapes. Lives outside the adapter so
/// integration tests can verify the exact subcommand sequences without
/// touching the live process runner, and so the CLI surface can evolve in
/// one place without ripple changes through the UI layer.
struct PiAgentCommandProfile: Sendable, Equatable {
    /// Command that probes whether the Pi agent app/instance is running.
    /// Stdout is expected to contain either a `running` substring or a
    /// `PID` token when alive — same heuristic Hermes uses for its
    /// dashboard.
    let appStatusArguments: [String]
    /// Command that launches the Pi agent app/instance detached.
    let launchAppArguments: [String]
    /// Command that starts the Pi gateway in the background.
    let startGatewayArguments: [String]
    /// Command that installs the Pi gateway runtime (called when
    /// `startGatewayArguments` fails the first time).
    let installGatewayArguments: [String]
    /// Optional command that lists Pi instances. When non-nil, the adapter
    /// can supplement Redis discovery with a CLI-side enumeration.
    let listInstancesArguments: [String]?

    static let live = PiAgentCommandProfile(
        appStatusArguments: ["agent", "status"],
        launchAppArguments: ["agent", "start", "--detach"],
        startGatewayArguments: ["gateway", "start", "--accept-hooks"],
        installGatewayArguments: ["gateway", "install", "--force", "--accept-hooks"],
        listInstancesArguments: ["agent", "list", "--json"]
    )
}
