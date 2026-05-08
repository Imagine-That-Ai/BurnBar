import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Hub View
//
// Aurora-styled grouped settings. Replaces the hodge-podge of `iPad*Settings`
// forms with one cohesive surface that re-uses native `Form` while restyling
// the chrome.

struct SettingsHubView: View {
    let authStore: AuthStore

    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("usageDisplayMode") private var usageDisplayMode: String = "currency"
    @AppStorage("uiMode") private var uiMode: String = UIMode.standard.rawValue
    @AppStorage("dailyBudget") private var dailyBudget: Double = 50.0
    @AppStorage("dailyDigestEnabled") private var dailyDigestEnabled: Bool = false
    @AppStorage("dailyDigestHour") private var dailyDigestHour: Int = 9
    @AppStorage("sessionNotifications") private var sessionNotifications: Bool = false
    @AppStorage("tokenAlertEnabled") private var tokenAlertEnabled: Bool = false
    @AppStorage("tokenAlertThreshold") private var tokenAlertThreshold: Int = 100_000
    @AppStorage("costAlertEnabled") private var costAlertEnabled: Bool = false
    @AppStorage("costAlertThreshold") private var costAlertThreshold: Double = 10.0

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            Form {
                Section {
                    Picker(selection: $preferredAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        SettingsLabel(icon: "paintpalette.fill", color: MobileTheme.amber, title: "Theme")
                    }
                    Picker(selection: $usageDisplayMode) {
                        Text("Currency").tag("currency")
                        Text("Tokens").tag("tokens")
                    } label: {
                        SettingsLabel(icon: "number.square.fill", color: MobileTheme.ember, title: "Default display")
                    }
                } header: { groupHeader("Appearance") }

                Section {
                    UIModePicker(selection: $uiMode)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                } header: { groupHeader("UI Mode") }

                Section {
                    HStack {
                        SettingsLabel(icon: "dollarsign.circle.fill", color: MobileTheme.amber, title: "Daily budget")
                        Spacer()
                        Text("$\(dailyBudget, specifier: "%.2f")")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Slider(value: $dailyBudget, in: 1...500, step: 5) {
                        Text("Daily budget")
                    } minimumValueLabel: {
                        Text("$1").font(MobileTheme.Typography.tiny).foregroundStyle(MobileTheme.Colors.textMuted)
                    } maximumValueLabel: {
                        Text("$500").font(MobileTheme.Typography.tiny).foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .tint(MobileTheme.ember)
                    Toggle(isOn: $costAlertEnabled) {
                        SettingsLabel(icon: "bell.badge.fill", color: MobileTheme.warning, title: "Cost alerts")
                    }
                    .tint(MobileTheme.ember)
                    if costAlertEnabled {
                        Stepper("Threshold: $\(costAlertThreshold, specifier: "%.2f")", value: $costAlertThreshold, step: 1)
                    }
                    Toggle(isOn: $tokenAlertEnabled) {
                        SettingsLabel(icon: "number.circle.fill", color: MobileTheme.amber, title: "Token alerts")
                    }
                    .tint(MobileTheme.ember)
                    if tokenAlertEnabled {
                        Stepper("Threshold: \(tokenAlertThreshold.formatted()) tokens", value: $tokenAlertThreshold, step: 10_000)
                    }
                } header: { groupHeader("Budget") }

                Section {
                    Toggle(isOn: $dailyDigestEnabled) {
                        SettingsLabel(icon: "envelope.badge.fill", color: MobileTheme.whimsy, title: "Daily digest")
                    }
                    .tint(MobileTheme.ember)
                    if dailyDigestEnabled {
                        Picker("Delivery time", selection: $dailyDigestHour) {
                            ForEach(6..<24, id: \.self) { hour in Text("\(hour):00").tag(hour) }
                        }
                    }
                    Toggle(isOn: $sessionNotifications) {
                        SettingsLabel(icon: "bell.fill", color: MobileTheme.amber, title: "Session pings")
                    }
                    .tint(MobileTheme.ember)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        SettingsLabel(icon: "gear", color: MobileTheme.Colors.textSecondary, title: "Open system Notifications…")
                    }
                    .foregroundStyle(MobileTheme.ember)
                } header: { groupHeader("Notifications") }

                Section {
                    NavigationLink {
                        ProviderConnectionsView(showsDoneButton: false)
                    } label: {
                        SettingsLabel(icon: "externaldrive.connected.to.line.below", color: MobileTheme.ember, title: "Provider connections")
                    }
                } header: { groupHeader("Providers") }

                Section {
                    NavigationLink {
                        HermesSettingsView(
                            service: HermesService(),
                            authStore: authStore
                        )
                    } label: {
                        SettingsLabel(icon: "antenna.radiowaves.left.and.right", color: MobileTheme.hermesAureate, title: "Hermes")
                    }
                } header: { groupHeader("Hermes") }

                Section {
                    LabeledContent("Version", value: marketingVersion)
                    LabeledContent("Build", value: buildVersion)
                    Link(destination: URL(string: "https://openburnbar.com/privacy")!) {
                        SettingsLabel(icon: "hand.raised.fill", color: MobileTheme.whimsy, title: "Privacy policy")
                    }
                    Link(destination: URL(string: "https://openburnbar.com/terms")!) {
                        SettingsLabel(icon: "doc.text.fill", color: MobileTheme.amber, title: "Terms of service")
                    }
                } header: { groupHeader("About") }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .tracking(1.4)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }

    private var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Settings Label

private struct SettingsLabel: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        Label {
            Text(title)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        } icon: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color)
                    .frame(width: 26, height: 26)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}
