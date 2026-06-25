import Foundation
@preconcurrency import SwiftUI
import OpenBurnBarCore

enum MacCloudStoreLegalURLs {
    static let privacy = URL(string: "https://burnbar.ai/legal/privacy-policy")!
    static let terms = URL(string: "https://burnbar.ai/legal/terms")!
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
