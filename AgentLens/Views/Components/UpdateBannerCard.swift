import SwiftUI

// The "update available" card. One component, rendered into the popover
// (compact), the dashboard, and settings. It reads everything from the shared
// checker's observable `phase`, so all three surfaces stay in lock-step through
// download → verify → install → relaunch.
//
// Compiled out of the sandboxed Mac App Store build, which updates through the
// App Store.
#if !DISTRIBUTION_MAS

struct UpdateBannerCard: View {
    /// Tighter layout for the 340pt menu-bar popover.
    var compact: Bool = false
    /// Edge insets applied only when the banner is actually shown, so an idle
    /// banner contributes zero size (no phantom gap in the popover stack).
    var horizontalInset: CGFloat = 0
    var topInset: CGFloat = 0

    @AppStorage(DirectDownloadUpdateChecker.oneClickSourceUpdateKey)
    private var oneClickSourceEnabled = false

    private static let releasesPageURL =
        URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest")!

    var body: some View {
        // Reading `.shared.phase` inside body registers SwiftUI observation, so
        // every surface re-renders as the update progresses.
        let checker = DirectDownloadUpdateChecker.shared
        let phase = checker.phase

        Group {
            if phase.isActionable {
                card(for: phase, channel: checker.channel, checker: checker)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, topInset)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.standard, value: phase)
    }

    // MARK: Card

    @ViewBuilder
    private func card(
        for phase: UpdatePhase,
        channel: UpdateChannel,
        checker: DirectDownloadUpdateChecker
    ) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: compact ? DesignSystem.Spacing.sm : DesignSystem.Spacing.md) {
                header(phase: phase, channel: channel)

                if !compact, let subtitle = subtitle(for: phase, channel: channel) {
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                body(for: phase, channel: channel, checker: checker)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? DesignSystem.Spacing.sm : DesignSystem.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: phase, channel: channel))
    }

    // MARK: Header

    @ViewBuilder
    private func header(phase: UpdatePhase, channel: UpdateChannel) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            iconDisc(systemName: icon(for: phase), gradient: iconGradient(for: phase))

            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: phase, channel: channel))
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if compact, let subtitle = subtitle(for: phase, channel: channel) {
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.xs)

            if let offer = phase.offer {
                versionPill(offer.pillText)
            }
        }
    }

    private func iconDisc(systemName: String, gradient: LinearGradient) -> some View {
        Image(systemName: systemName)
            .font(.system(size: compact ? 13 : 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
            .background(Circle().fill(gradient))
            .shadow(color: DesignSystem.Colors.ember.opacity(0.3), radius: 4, y: 1)
    }

    private func versionPill(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
            .fixedSize()
    }

    // MARK: Body (progress or actions)

    @ViewBuilder
    private func body(
        for phase: UpdatePhase,
        channel: UpdateChannel,
        checker: DirectDownloadUpdateChecker
    ) -> some View {
        switch phase {
        case let .available(offer):
            actions(for: offer, channel: channel, checker: checker)

        case let .downloading(progress):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ProgressView(value: progress)
                    .tint(DesignSystem.Colors.ember)
                Text("Downloading… \(Int((progress * 100).rounded()))%")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .contentTransition(.numericText())
            }

        case .verifying:
            indeterminate("Verifying signature…")
        case .installing:
            indeterminate("Installing…")
        case .relaunching:
            indeterminate("Relaunching…")

        case let .failed(message):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                if !compact {
                    Text(message)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DesignSystem.Spacing.sm) {
                    GlassButton(title: "Check Again", icon: "arrow.clockwise", style: .prominent) {
                        checker.checkForUpdatesNow()
                    }
                    if !compact {
                        GlassButton(title: "Releases", icon: "safari", style: .regular) {
                            NSWorkspace.shared.open(Self.releasesPageURL)
                        }
                    }
                }
            }

        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func indeterminate(_ label: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private func actions(
        for offer: UpdateOffer,
        channel: UpdateChannel,
        checker: DirectDownloadUpdateChecker
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            switch offer {
            case .directDMG:
                GlassButton(title: "Install Update", icon: "arrow.down.circle.fill", style: .prominent) {
                    checker.install()
                }
                if !compact {
                    GlassButton(title: "Later", icon: "clock", style: .regular) {
                        checker.dismiss()
                    }
                }

            case .homebrew:
                GlassButton(title: "Update via Homebrew", icon: "terminal", style: .prominent) {
                    checker.updateViaHomebrew()
                }
                if !compact {
                    GlassButton(title: "Later", icon: "clock", style: .regular) {
                        checker.dismiss()
                    }
                }

            case .source:
                if oneClickSourceEnabled {
                    GlassButton(title: "Pull · Rebuild", icon: "hammer.fill", style: .prominent) {
                        checker.runSourceUpdate()
                    }
                } else {
                    GlassButton(title: "Update in Terminal", icon: "terminal", style: .prominent) {
                        checker.openSourceUpdateInTerminal()
                    }
                }
                if !compact {
                    GlassButton(title: "View Changes", icon: "arrow.triangle.branch", style: .regular) {
                        checker.openSourceChanges()
                    }
                }
            }
        }
    }

    // MARK: Copy

    private func icon(for phase: UpdatePhase) -> String {
        switch phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .verifying: return "checkmark.shield.fill"
        case .installing, .relaunching: return "sparkles"
        default: return "arrow.down.circle.fill"
        }
    }

    private func iconGradient(for phase: UpdatePhase) -> LinearGradient {
        if case .failed = phase {
            return LinearGradient(
                colors: [DesignSystem.Colors.error, DesignSystem.Colors.error.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return DesignSystem.Colors.primaryGradient
    }

    private func title(for phase: UpdatePhase, channel: UpdateChannel) -> String {
        switch phase {
        case .available:
            if case .available(.source) = phase { return "New commits available" }
            return "Update available"
        case .downloading: return "Downloading update"
        case .verifying: return "Verifying update"
        case .installing: return "Installing update"
        case .relaunching: return "Relaunching"
        case .failed: return "Update didn't finish"
        case .idle, .checking, .upToDate: return ""
        }
    }

    private func subtitle(for phase: UpdatePhase, channel: UpdateChannel) -> String? {
        guard case let .available(offer) = phase else { return nil }
        switch offer {
        case let .directDMG(release):
            return release.critical
                ? "A security fix is ready. It’ll be verified, installed, and relaunched for you."
                : "A new version is ready. It’ll be verified, installed, and relaunched for you."
        case .homebrew:
            return "A newer version is available. Update it through Homebrew."
        case let .source(status):
            let branch = status.defaultBranch
            return status.behindBy == 1
                ? "Your build is 1 commit behind \(branch)."
                : "Your build is \(status.behindBy) commits behind \(branch)."
        }
    }

    private func accessibilityLabel(for phase: UpdatePhase, channel: UpdateChannel) -> String {
        let base = title(for: phase, channel: channel)
        if let subtitle = subtitle(for: phase, channel: channel) {
            return "\(base). \(subtitle)"
        }
        return base
    }
}
#endif
