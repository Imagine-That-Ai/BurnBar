import Foundation
@preconcurrency import SwiftUI
import OpenBurnBarCore

enum MacCloudStoreLegalURLs {
    static let privacy = requiredURL("https://burnbar.ai/legal/privacy-policy")
    static let terms = requiredURL("https://burnbar.ai/legal/terms")
}

/// The member web console at app.burnbar.ai — the Data & Privacy Control
/// Center on the web. One source of truth for every macOS surface that links
/// out to it (Cloud pane, Memory walkthrough, Data & Privacy landing).
enum MacCloudConsoleURLs {
    static let root = requiredURL("https://app.burnbar.ai")
    static let pensieve = requiredURL("https://app.burnbar.ai/pensieve")
}

private func requiredURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("Invalid compile-time URL: \(string)")
    }
    return url
}

struct MacCloudStoreLegalLinks: View {
    var body: some View {
        HStack(spacing: 8) {
            Link("Privacy Policy", destination: MacCloudStoreLegalURLs.privacy)
            Text("·")
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Link("Terms of Use (EULA)", destination: MacCloudStoreLegalURLs.terms)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DesignSystem.Colors.ember)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("macCloudStore.legalLinks")
    }
}
