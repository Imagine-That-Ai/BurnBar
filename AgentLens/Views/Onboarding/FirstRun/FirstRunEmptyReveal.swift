import SwiftUI

// MARK: - The Empty Reveal
//
// Most first-run designs die here: the user installs a tool, it finds nothing,
// and it blames them for it ("Connect a provider in Settings → Connections").
// That sentence pushes a stranger toward the exact sign-in this product is
// proud of not needing, on the one screen where they have the least reason to
// trust us.
//
// This screen does the opposite. It says what we did, how hard we looked, and
// that they do not have to come back — because the app will notice on its own
// and tell them. An empty state that promises to stop being empty is the most
// reassuring screen in the product.

struct FirstRunEmptyReveal: View {
    /// Rendered live from `ParserRegistry`, never hardcoded — the same
    /// discipline the website's provider count uses. A stale number here would
    /// be a small lie on the screen whose entire job is trust.
    let searchedPathCount: Int
    var onWatchForIt: () -> Void = {}
    var onShowPathAudit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("NOTHING HERE YET")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Text("Nothing on this Mac has burned a token yet — and I looked in \(searchedPathCount) places.")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 1)

            Text("The moment Claude Code, Codex or Cursor writes its first session file, this fills in by itself. You don't have to come back.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Watch for it") { onWatchForIt() }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
                .controlSize(.small)

            Button("Where did you look?") { onShowPathAudit() }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Empty reveal") {
    FirstRunEmptyReveal(searchedPathCount: 32)
        .padding()
        .frame(width: 340)
}
