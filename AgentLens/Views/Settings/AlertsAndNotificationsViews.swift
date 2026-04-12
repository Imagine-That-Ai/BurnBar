import SwiftUI

// MARK: - Alerts Settings View

struct AlertsSettingsView: View {
    @Bindable var settingsManager: SettingsManager

    private var costAlertBinding: Binding<Double> {
        Binding(
            get: { settingsManager.costAlertThreshold ?? 0 },
            set: { settingsManager.costAlertThreshold = $0 > 0 ? $0 : nil }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                SettingsSectionHeader(title: "Spend Alerts")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        SettingsToggle(
                            title: "Cost threshold alert",
                            subtitle: "Highlight unusually expensive usage days before spend quietly drifts upward.",
                            icon: "dollarsign.circle",
                            isOn: Binding(
                                get: { settingsManager.costAlertThreshold != nil },
                                set: { enabled in
                                    settingsManager.costAlertThreshold = enabled
                                        ? max(settingsManager.costAlertThreshold ?? 25, 1)
                                        : nil
                                }
                            )
                        )

                        if settingsManager.costAlertThreshold != nil {
                            Divider().background(DesignSystem.Colors.border)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Daily threshold")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    Text("Warn when estimated daily burn crosses this amount.")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                HStack(spacing: DesignSystem.Spacing.xs) {
                                    Text("$")
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                    TextField("25", value: costAlertBinding, format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 96)
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                SettingsSectionHeader(title: "Digest")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        SettingsToggle(
                            title: "Daily digest",
                            subtitle: "Get one compact reality check instead of finding out at month end.",
                            icon: "newspaper",
                            isOn: $settingsManager.dailyDigestEnabled
                        )

                        if settingsManager.dailyDigestEnabled {
                            Divider().background(DesignSystem.Colors.border)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Delivery hour")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    Text("Local time on this Mac.")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                Picker("", selection: $settingsManager.dailyDigestHour) {
                                    ForEach(0..<24, id: \.self) { hour in
                                        Text(String(format: "%02d:00", hour)).tag(hour)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 110)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Notifications Settings View

struct NotificationsSettingsView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                SettingsSectionHeader(title: "Local Notifications")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        SettingsToggle(
                            title: "Controller local notifications",
                            subtitle: "Allow the daemon-backed runtime to nudge you about followups and pending work on this Mac.",
                            icon: "app.badge",
                            isOn: $settingsManager.controllerLocalNotificationsEnabled
                        )
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                SettingsSectionHeader(title: "Controller Channels")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        SettingsToggle(
                            title: "Telegram bridge",
                            subtitle: "Enable Telegram commands and followup delivery when a bot token and chat ID are configured.",
                            icon: "paperplane",
                            isOn: $settingsManager.controllerTelegramEnabled
                        )

                        if settingsManager.controllerTelegramEnabled {
                            Divider().background(DesignSystem.Colors.border)
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                                SecureField("Telegram bot token", text: $settingsManager.controllerTelegramBotToken)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Telegram chat ID", text: $settingsManager.controllerTelegramChatID)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Divider().background(DesignSystem.Colors.border)

                        SettingsToggle(
                            title: "Calendar integration",
                            subtitle: "Allow OpenBurnBar to create local calendar placeholders for scheduled followups.",
                            icon: "calendar",
                            isOn: $settingsManager.controllerCalendarIntegrationEnabled
                        )

                        if settingsManager.controllerCalendarIntegrationEnabled {
                            Divider().background(DesignSystem.Colors.border)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Default calendar hold")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    Text("Used for new followup calendar events.")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                Picker("", selection: $settingsManager.controllerCalendarDefaultMinutes) {
                                    ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                                        Text("\(minutes) min").tag(minutes)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 110)
                            }
                        }

                        Divider().background(DesignSystem.Colors.border)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Default snooze window")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                Text("Applied when OpenBurnBar creates or defers followups.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer()
                            Picker("", selection: $settingsManager.controllerDefaultSnoozeMinutes) {
                                ForEach([30, 60, 90, 120, 180, 240], id: \.self) { minutes in
                                    Text("\(minutes) min").tag(minutes)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 110)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }
}
