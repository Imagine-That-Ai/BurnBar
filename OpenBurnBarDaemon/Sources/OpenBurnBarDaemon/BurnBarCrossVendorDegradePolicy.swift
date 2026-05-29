import Foundation

/// Opt-in, off-by-default policy for cross-vendor degrade routing (Part B3).
///
/// When the model the client asked for cannot be served — its own provider
/// family is exhausted (e.g. the Anthropic budget is gone) or the user holds no
/// credential for it at all — the gateway can, **only if the operator opts in**,
/// substitute a different, cheaper model from an allow-listed OpenAI-compatible
/// vendor running on the user's own API key. This deliberately relaxes the
/// router's exact-canonical-model invariant, so it is never on by default and is
/// logged loudly whenever it fires.
///
/// The degrade target is always an OpenAI-compatible vendor and this only runs
/// on the OpenAI chat endpoint, so the response wire format already matches the
/// client — no cross-format translation is involved.
public struct BurnBarCrossVendorDegradePolicy: Sendable, Hashable {
    /// Master switch. Defaults to `false`; the gateway behaves identically to
    /// the pre-B3 build whenever this is off.
    public var isEnabled: Bool
    /// Allow-listed OpenAI-compatible vendor provider IDs, in preference order.
    public var allowedVendorIDs: [String]
    /// Preferred degrade model per vendor; falls back to the vendor's first
    /// public catalog model when absent or unresolvable.
    public var preferredModelByVendorID: [String: String]
    /// Hard cap on the number of degrade candidates attempted per request.
    public var maxCandidates: Int

    public static let defaultVendorIDs = ["deepseek", "zai", "moonshot"]

    public static let defaultPreferredModels: [String: String] = [
        "deepseek": "deepseek-chat",
        "zai": "glm-4.6",
        "moonshot": "kimi-k2"
    ]

    /// The canonical off state used everywhere degrade has not been requested.
    public static let disabled = BurnBarCrossVendorDegradePolicy(
        isEnabled: false,
        allowedVendorIDs: defaultVendorIDs,
        preferredModelByVendorID: defaultPreferredModels,
        maxCandidates: 4
    )

    public init(
        isEnabled: Bool,
        allowedVendorIDs: [String] = BurnBarCrossVendorDegradePolicy.defaultVendorIDs,
        preferredModelByVendorID: [String: String] = BurnBarCrossVendorDegradePolicy.defaultPreferredModels,
        maxCandidates: Int = 4
    ) {
        self.isEnabled = isEnabled
        self.allowedVendorIDs = allowedVendorIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        self.preferredModelByVendorID = Dictionary(
            uniqueKeysWithValues: preferredModelByVendorID.map { ($0.key.lowercased(), $0.value) }
        )
        self.maxCandidates = max(1, maxCandidates)
    }

    public func allows(providerID: String) -> Bool {
        allowedVendorIDs.contains(providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Builds a policy from the process environment. Off unless explicitly
    /// enabled via `OPENBURNBAR_CROSS_VENDOR_DEGRADE` (1/true/yes/on). An
    /// optional comma-separated `OPENBURNBAR_CROSS_VENDOR_DEGRADE_VENDORS`
    /// narrows or reorders the vendor allow-list.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BurnBarCrossVendorDegradePolicy {
        let flag = environment["OPENBURNBAR_CROSS_VENDOR_DEGRADE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let enabled = flag == "1" || flag == "true" || flag == "yes" || flag == "on"
        guard enabled else { return .disabled }

        var vendors = defaultVendorIDs
        if let raw = environment["OPENBURNBAR_CROSS_VENDOR_DEGRADE_VENDORS"] {
            let parsed = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            if !parsed.isEmpty {
                vendors = parsed
            }
        }

        return BurnBarCrossVendorDegradePolicy(
            isEnabled: true,
            allowedVendorIDs: vendors,
            preferredModelByVendorID: defaultPreferredModels,
            maxCandidates: 4
        )
    }
}
