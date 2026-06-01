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
            avatar
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

    // MARK: - Avatar

    @ViewBuilder
    private var avatar: some View {
        if let monogram {
            ZStack {
                Circle().fill(Color(.systemGray2))
                Text(monogram)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 60))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived text

    private var primaryLine: String {
        if let identity = authStore.currentIdentity {
            return identity.displayName ?? identity.email ?? "OpenBurnBar account"
        }
        return "Sign in for Cloud"
    }

    /// First letter of the display name / email, used as a monogram when the
    /// account has no photo. `nil` when signed out (falls back to the SF Symbol).
    private var monogram: String? {
        guard let identity = authStore.currentIdentity else { return nil }
        let source = identity.displayName ?? identity.email ?? ""
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(first).uppercased()
    }
}
