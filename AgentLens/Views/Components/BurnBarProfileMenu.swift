import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - BurnBar Profile Menu

/// Floating profile menu presented from the profile avatar.
/// Acts as an identity-first command center and replaces legacy standalone settings/overflow buttons.
struct BurnBarProfileMenu: View {
    var onOpenDashboard: (() -> Void)?
    var onOpenSettings: () -> Void
    var onOpenSettingsTab: ((SettingsTab) -> Void)?
    var onOpenSettingsItem: ((String) -> Void)?
    var isScanning: Bool = false
    var onImport: (() -> Void)?
    var onRecount: (() -> Void)?
    var canRunRecount: Bool = true
    var onCastSmartDisplay: (() -> Void)?
    var isCastingSmartDisplay: Bool = false
    var mtdSpendFormatted: String?
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(AccountManager.self) private var accountManager
    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @AppStorage(PetCompanionFeature.DefaultsKey.enabled) private var petCompanionEnabled = false
    @AppStorage(KernelBackdropPreferences.enabledKey) private var useKernelBackdrop = false
    @AppStorage(KernelBackdropPreferences.kernelKey) private var backdropKernel = KernelCatalog.defaultID

    var body: some View {
        VStack(spacing: 0) {
            identityHeaderSection
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            menuDivider

            if let mtdSpendFormatted, !mtdSpendFormatted.isEmpty {
                spendGlanceSection(spend: mtdSpendFormatted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                menuDivider
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    navigationSection
                    menuDivider
                        .padding(.vertical, 2)
                    actionsSection
                    menuDivider
                        .padding(.vertical, 2)
                    appearanceQuickSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 280)

            menuDivider

            footerSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.02)
                        : Color.black.opacity(0.02)
                )
        }
        .frame(width: 290)
        .background(menuBackgroundSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark
                        ? Color.white.opacity(0.14)
                        : Color.black.opacity(0.10),
                    lineWidth: 0.75
                )
        )
        .onAppear {
            entitlement.start()
        }
    }

    // MARK: - Background Surface

    @ViewBuilder
    private var menuBackgroundSurface: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .liquidGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.65))
            }
        }
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(0.08)
                    : Color.black.opacity(0.06)
            )
            .frame(height: 0.5)
    }

    // MARK: - Identity Header Section

    private var identityHeaderSection: some View {
        HStack(spacing: 12) {
            BurnBarProfileAvatar(
                size: .header,
                avatarURL: accountManager.avatarURL,
                displayName: accountManager.userDisplayName,
                email: accountManager.userEmail,
                tier: entitlement.currentTier,
                showTierRing: true,
                showStatusBadge: true,
                isLiveOrSyncing: accountManager.isCloudSyncEnabled
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(accountManager.userDisplayName ?? "BurnBar User")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    tierBadgeView(tier: entitlement.currentTier)
                }

                Text(accountManager.userEmail ?? "Local Device Workspace")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle()
                        .fill(accountManager.isSignedIn ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                        .frame(width: 5, height: 5)

                    Text(accountManager.isSignedIn ? "Cloud Sync Active" : "Offline Local Vault")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Tier Badge Pill

    private func tierBadgeView(tier: MacCloudTier) -> some View {
        Button {
            routeToSettingsTab(.cloud)
        } label: {
            HStack(spacing: 2) {
                switch tier {
                case .ultra:
                    Text("ULTRA")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color(hex: "F39C12"), Color(hex: "8E44AD")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                case .pro:
                    Text("PRO")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(DesignSystem.Colors.primaryGradient)
                        )
                case .cloud:
                    Text("CLOUD")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(DesignSystem.Colors.whimsyGradient)
                        )
                case .free:
                    Text("FREE")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.75)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .help("Manage membership in Settings")
    }

    // MARK: - Spend Glance Section

    private func spendGlanceSection(spend: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("CURRENT PERIOD BURN")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text(spend)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Spacer(minLength: 0)

            Button {
                dismissMenu()
                if let onOpenDashboard {
                    onOpenDashboard()
                } else {
                    onOpenSettings()
                }
            } label: {
                HStack(spacing: 3) {
                    Text(onOpenDashboard != nil ? "Dashboard" : "Details")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(DesignSystem.Colors.ember)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.ember.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Navigation Section

    private var navigationSection: some View {
        VStack(spacing: 2) {
            if let onOpenDashboard {
                menuRowButton(
                    icon: "chart.bar.xaxis",
                    title: "Open Dashboard",
                    subtitle: "Detailed charts, breakdown & ledger",
                    color: DesignSystem.Colors.ember
                ) {
                    dismissMenu()
                    onOpenDashboard()
                }
                .accessibilityIdentifier(OBBAccessibilityID.popoverDashboardButton)
            }

            menuRowButton(
                icon: "gearshape.fill",
                title: "All Settings…",
                shortcut: "⌘,",
                color: DesignSystem.Colors.textSecondary
            ) {
                dismissMenu()
                onOpenSettings()
            }
            .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)

            menuRowButton(
                icon: "cpu.fill",
                title: "Agents & Providers",
                subtitle: "Cloud keys and CLI paths",
                color: DesignSystem.Colors.ember
            ) {
                routeToSettingsTab(.agents)
            }

            menuRowButton(
                icon: "tray.full.fill",
                title: "AI Inbox",
                subtitle: "Automated activity analysis",
                color: DesignSystem.Colors.whimsy
            ) {
                routeToSettingsTab(.aiInbox)
            }

            menuRowButton(
                icon: "cpu",
                title: "Engine Room",
                subtitle: "Daemon runtime status",
                color: DesignSystem.Colors.amber
            ) {
                routeToSettingsTab(.daemon)
            }

            menuRowButton(
                icon: "lock.shield.fill",
                title: "Data & Privacy",
                subtitle: "Vault, exports, and redactions",
                color: DesignSystem.Colors.textSecondary
            ) {
                routeToSettingsTab(.dataPrivacy)
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 2) {
            // Pet Companion toggle row
            HStack(spacing: 10) {
                Image(systemName: petCompanionEnabled ? "pawprint.fill" : "pawprint")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Desktop Pet")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(petCompanionEnabled ? "Active on desktop" : "Hidden")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { petCompanionEnabled },
                    set: { _ in PetCompanionFeature.toggleCompanion() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())

            // Mine / Refresh logs row
            if let onImport {
                menuRowButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: isScanning ? "Mining Session Logs…" : "Refresh Spend (Scan)",
                    color: isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary
                ) {
                    onImport()
                }
                .disabled(isScanning)
            }

            // Recount totals row
            if let onRecount {
                menuRowButton(
                    icon: "arrow.counterclockwise",
                    title: "Recount Totals",
                    color: DesignSystem.Colors.textSecondary
                ) {
                    onRecount()
                }
                .disabled(!canRunRecount)
            }

            // Smart display casting row
            if let onCastSmartDisplay {
                menuRowButton(
                    icon: "airplayvideo",
                    title: isCastingSmartDisplay ? "Casting to Display…" : "Cast to Smart Display",
                    color: isCastingSmartDisplay ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary
                ) {
                    onCastSmartDisplay()
                }
                .disabled(isCastingSmartDisplay)
            }
        }
    }

    // MARK: - Appearance Quick Section

    private var appearanceQuickSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("APPEARANCE")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                Button {
                    routeToSettingsTab(.general)
                } label: {
                    Text("More…")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            HStack(spacing: 4) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        settingsManager.appearanceMode = mode
                    } label: {
                        Text(mode.quickMenuLabel)
                            .font(.system(size: 10.5, weight: settingsManager.appearanceMode == mode ? .bold : .medium, design: .rounded))
                            .foregroundStyle(
                                settingsManager.appearanceMode == mode
                                    ? DesignSystem.Colors.textPrimary
                                    : DesignSystem.Colors.textSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        settingsManager.appearanceMode == mode
                                            ? DesignSystem.Colors.surfaceElevated
                                            : Color.clear
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        settingsManager.appearanceMode == mode
                                            ? DesignSystem.Colors.borderSubtle
                                            : Color.clear,
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
            )
            .padding(.horizontal, 6)
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack(spacing: 8) {
            Button {
                routeToSettingsTab(.account)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(accountManager.isSignedIn ? "Account" : "Sign In")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // App Store Guideline 2.1 visible Quit command
            GlassButton(
                title: "Quit OpenBurnBar",
                icon: "power",
                style: .cool
            ) {
                NSApplication.shared.terminate(nil)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Quit OpenBurnBar")
        }
    }

    // MARK: - Helpers & Row Components

    private func menuRowButton(
        icon: String,
        title: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        ProfileMenuRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            shortcut: shortcut,
            color: color,
            action: action
        )
    }

    private func routeToSettingsTab(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsDeepLinkRouting.pendingTabKey)
        dismissMenu()
        if let onOpenSettingsTab {
            onOpenSettingsTab(tab)
        } else {
            onOpenSettings()
        }
    }

    private func dismissMenu() {
        onDismiss?()
    }
}

// MARK: - Profile Menu Row

private struct ProfileMenuRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var shortcut: String?
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    if let subtitle {
                        Text(subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.8))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? DesignSystem.Colors.surfaceElevated.opacity(0.6) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Floating Profile Avatar Button

/// Composable interactive button presenting the floating profile menu in a popover.
struct BurnBarProfileAvatarButton: View {
    var size: BurnBarProfileAvatarSize = .toolbar
    var onOpenDashboard: (() -> Void)?
    var onOpenSettings: () -> Void
    var onOpenSettingsTab: ((SettingsTab) -> Void)?
    var onOpenSettingsItem: ((String) -> Void)?
    var isScanning: Bool = false
    var onImport: (() -> Void)?
    var onRecount: (() -> Void)?
    var canRunRecount: Bool = true
    var onCastSmartDisplay: (() -> Void)?
    var isCastingSmartDisplay: Bool = false
    var mtdSpendFormatted: String?

    @State private var isMenuPresented = false
    @State private var isHovered = false
    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @Environment(AccountManager.self) private var accountManager

    var body: some View {
        Button {
            isMenuPresented.toggle()
        } label: {
            BurnBarProfileAvatar(
                size: size,
                avatarURL: accountManager.avatarURL,
                displayName: accountManager.userDisplayName,
                email: accountManager.userEmail,
                tier: entitlement.currentTier,
                showTierRing: true,
                showStatusBadge: true,
                isLiveOrSyncing: isScanning || accountManager.isCloudSyncEnabled
            )
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(DesignSystem.Animation.hover, value: isHovered)
            .shadow(
                color: DesignSystem.Colors.ember.opacity(isHovered ? 0.35 : 0.0),
                radius: 6,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Profile, Cloud membership, and Settings")
        .accessibilityLabel("Profile and Settings")
        .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)
        .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) {
            BurnBarProfileMenu(
                onOpenDashboard: onOpenDashboard != nil ? {
                    isMenuPresented = false
                    onOpenDashboard?()
                } : nil,
                onOpenSettings: {
                    isMenuPresented = false
                    onOpenSettings()
                },
                onOpenSettingsTab: { tab in
                    isMenuPresented = false
                    onOpenSettingsTab?(tab)
                },
                onOpenSettingsItem: { item in
                    isMenuPresented = false
                    onOpenSettingsItem?(item)
                },
                isScanning: isScanning,
                onImport: onImport,
                onRecount: onRecount,
                canRunRecount: canRunRecount,
                onCastSmartDisplay: onCastSmartDisplay,
                isCastingSmartDisplay: isCastingSmartDisplay,
                mtdSpendFormatted: mtdSpendFormatted,
                onDismiss: { isMenuPresented = false }
            )
        }
    }
}
