import SwiftUI

// Settings → Updates. Shows the current version + channel, the live update
// banner when something is pending, a manual "Check for Updates" action, and
// the update preferences (automatic checks, pre-release channel, one-click
// source rebuild). Compiled out of the Mac App Store build.
#if !DISTRIBUTION_MAS

struct UpdatesSettingsView: View {
    @AppStorage(DirectDownloadUpdateChecker.automaticChecksKey) private var automaticChecks = true
    @AppStorage(DirectDownloadUpdateChecker.prereleaseChannelKey) private var prereleaseChannel = false
    @AppStorage(DirectDownloadUpdateChecker.oneClickSourceUpdateKey) private var oneClickSource = false

    private static let releasesPageURL =
        URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases")!

    var body: some View {
        let checker = DirectDownloadUpdateChecker.shared

        SettingsDeepLinkScrollContainer(route: .updatesRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    versionCard(channel: checker.channel)
                        .settingsAnchor(SettingsAnchor.updatesOverview)

                    UpdateBannerCard()

                    preferences(channel: checker.channel)

                    actions(checker: checker)

                    Spacer(minLength: 0)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Version

    @ViewBuilder
    private func versionCard(channel: UpdateChannel) -> some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let sha = info["OpenBurnBarGitCommit"] as? String

        HStack(spacing: DesignSystem.Spacing.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenBurnBar")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Version \(version) (\(build))")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                HStack(spacing: DesignSystem.Spacing.xs) {
                    channelBadge(channelLabel(channel))
                    if channel == .source, let sha, !sha.isEmpty {
                        Text(String(sha.prefix(11)))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .settingsAnchor(SettingsAnchor.updatesOverview)
    }

    private func channelBadge(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.frost)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(DesignSystem.Colors.frost.opacity(0.12))
            )
            .overlay(Capsule().strokeBorder(DesignSystem.Colors.frost.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: Preferences

    @ViewBuilder
    private func preferences(channel: UpdateChannel) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "AUTOMATIC UPDATES")

            SettingsToggle(
                title: "Automatically check for updates",
                subtitle: "Check shortly after launch and once a day",
                icon: "clock.arrow.circlepath",
                isOn: $automaticChecks
            )
            .settingsAnchor(SettingsAnchor.updatesAutomaticChecks)

            if channel == .dmg || channel == .homebrew {
                SettingsToggle(
                    title: "Receive pre-release builds",
                    subtitle: "Get cutting-edge versions before they're promoted to stable",
                    icon: "flask.fill",
                    isOn: $prereleaseChannel
                )
            }

            if channel == .source {
                SettingsToggle(
                    title: "Enable one-click source update",
                    subtitle: "Adds a Pull · Rebuild button that runs the build script for you",
                    icon: "hammer.fill",
                    isOn: $oneClickSource
                )
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(checker: DirectDownloadUpdateChecker) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Button {
                checker.checkForUpdatesNow()
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.ember)
            .controlSize(.large)

            Link(destination: Self.releasesPageURL) {
                Label("Release Notes", systemImage: "doc.text")
            }
            .foregroundStyle(DesignSystem.Colors.frost)

            Spacer(minLength: 0)
        }
        .settingsAnchor(SettingsAnchor.updatesReleaseNotes)
    }

    // MARK: Styling

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
            .fill(DesignSystem.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 1)
            )
    }

    private func channelLabel(_ channel: UpdateChannel) -> String {
        switch channel {
        case .dmg: return "Direct download"
        case .homebrew: return "Homebrew"
        case .source: return "Source build"
        case .unknown: return "Unmanaged build"
        }
    }
}
#endif
