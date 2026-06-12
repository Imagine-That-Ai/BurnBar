import Foundation

// MARK: - Setup Guide

struct OpenBurnBarSetupGuideSnapshot: Equatable, Sendable {
    let headline: String
    let localTitle: String
    let localDetail: String
    let cloudTitle: String
    let cloudDetail: String
    let runtimeTitle: String
    let runtimeDetail: String
    let providerHealthTitle: String
    let providerHealthDetail: String
}

enum OpenBurnBarSetupGuideBuilder {
    static func build(
        detection: [AgentProvider: Bool],
        indexingEnabled: Bool,
        isSignedIn: Bool,
        conversationCloudEnabled: Bool,
        iCloudMirrorEnabled: Bool,
        hermesAvailable: Bool? = nil,
        openClawAvailable: Bool? = nil
    ) -> OpenBurnBarSetupGuideSnapshot {
        let detectedCount = detection.values.filter { $0 }.count
        let gatewayParts: [String] = [
            statusLabel(name: "Hermes", ok: hermesAvailable),
            statusLabel(name: "OpenClaw", ok: openClawAvailable)
        ]
        .compactMap { $0 }

        let providerHealthDetail: String = {
            if gatewayParts.isEmpty {
                return "OpenBurnBar can scan \(detectedCount) provider source\(detectedCount == 1 ? "" : "s") from disk. Chat gateways stay optional until you want live companion models."
            }
            return gatewayParts.joined(separator: " · ")
        }()

        let runtimeTitle = detectedCount > 0 ? "Live local state" : "Static setup mode"
        let runtimeDetail = detectedCount > 0
            ? "OpenBurnBar can already see \(detectedCount) provider source\(detectedCount == 1 ? "" : "s") on this Mac. Your first scan turns the UI into live mission, direction, and burn state."
            : "OpenBurnBar can explain setup and safety right away, but mission and direction stay provisional until it sees local logs."

        let cloudDetail: String = {
            if isSignedIn {
                if conversationCloudEnabled || iCloudMirrorEnabled {
                    return "Authenticated features are on. OpenBurnBar can sync metadata across devices, and any iCloud mirror stays in your Apple account instead of OpenBurnBar's servers."
                }
                return "You are signed in, but cloud features are still optional. Local scans, burn, and indexed evidence work without turning sync on."
            }
            return "Cloud is optional. Sign in only if you want cross-device recall or shared artifacts. OpenBurnBar's local scans, burn, and index continue to work without auth."
        }()

        return OpenBurnBarSetupGuideSnapshot(
            headline: "OpenBurnBar is local-first: it reads your agent logs, builds a private operating picture on your Mac, and only uses auth when you explicitly turn on shared or cross-device features.",
            localTitle: "Local by default",
            localDetail: indexingEnabled
                ? "Scans, burn accounting, local search, evidence previews, and mission/direction summaries stay on this Mac."
                : "Scans and burn accounting stay local. Turn on local indexing when you want transcript-grounded evidence and better direction reads.",
            cloudTitle: "Cloud is optional",
            cloudDetail: cloudDetail,
            runtimeTitle: runtimeTitle,
            runtimeDetail: runtimeDetail,
            providerHealthTitle: "Provider setup health",
            providerHealthDetail: providerHealthDetail
        )
    }

    private static func statusLabel(name: String, ok: Bool?) -> String? {
        guard let ok else { return nil }
        return "\(name) \(ok ? "reachable" : "offline")"
    }
}
