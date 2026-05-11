import Foundation
import OpenBurnBarCore
import UIKit

// MARK: - iOS Smart Hub Display Adapter
//
// Forwards Nest Hub edits through `SmartHubStore` so the Mac sees them
// via Firestore. The Mac performs the actual HTTP work (port binding,
// state pumping, voice ping) and writes status back.

@MainActor
final class MobileSmartHubDisplayOperationsAdapter: SmartHubDisplayOperations {

    private let store: SmartHubStore

    init(store: SmartHubStore) {
        self.store = store
    }

    func updateDisplayConfig(_ config: SmartHubDisplayConfig) async {
        await store.updateDisplayConfig(config)
    }

    func testBridge() async -> SmartHubBridgeProbeStatus {
        // We can't probe the Mac's bridge directly from the phone — but
        // we *can* hit the same refresh URL the Mac publishes. A 2xx
        // there proves the bridge is bound and reachable from the iOS
        // device's network.
        guard let raw = store.config?.refreshURL,
              let url = URL(string: raw) else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return .bound
            }
            return .error
        } catch {
            return .unreachable
        }
    }

    func refreshNow() async {
        _ = try? await store.refreshNestHub()
    }

    func identify() async {
        _ = try? await store.identifyNestHub()
    }

    func stopBridge() async {
        _ = try? await store.stopNestHub()
    }

    func openInBrowser() async {
        guard let url = store.dashboardURL else { return }
        await UIApplication.shared.open(url)
    }

    func copyVoiceRoutineURL() async {
        guard let raw = store.config?.voiceRefreshURL,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIPasteboard.general.string = raw
    }
}
