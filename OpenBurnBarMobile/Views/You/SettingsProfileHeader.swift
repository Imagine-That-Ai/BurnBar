import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Profile Header
//
// Apple-ID-style banner shown as the first row of the Settings hub. Mirrors
// the profile cell at the top of Apple's stock Settings app: a large avatar,
// the account name (or a sign-in prompt), and a secondary status line.
// Rendered as the label of a `NavigationLink` to `AccountSettingsView`, so the
// system supplies the trailing chevron and tap affordance.

struct SettingsProfileHeader: View {
    let authStore: AuthStore
    let cloudStatus: String

    var body: some View {
        HStack(spacing: 14) {
            UserAvatarView(
                photoURL: authStore.currentIdentity?.photoURL,
                displayName: authStore.currentIdentity?.displayName ?? authStore.currentIdentity?.email,
                size: 60
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(cloudStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived text

    private var primaryLine: String {
        if let identity = authStore.currentIdentity {
            return identity.displayName ?? identity.email ?? "OpenBurnBar account"
        }
        return "Sign in for Cloud"
    }
}
