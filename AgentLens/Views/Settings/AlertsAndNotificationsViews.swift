import SwiftUI

// MARK: - Alerts Settings View (iOS-style landing)

struct AlertsSettingsView: View {
    @Bindable var settingsManager: SettingsManager

    private var costAlertBinding: Binding<Double> {
        Binding(
            get: { settingsManager.costAlertThreshold ?? 0 },
            set: { settingsManager.costAlertThreshold = $0 > 0 ? $0 : nil }
        )
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .alertsRoot) { _ in
            List {
                Section {
                    NavigationLink {
                        SpendAlertDetailView(
                            settingsManager: settingsManager,
                            costAlertBinding: costAlertBinding
                        )
                    } label: {
                        SettingsDrillRow(
                            icon: "dollarsign.circle.fill",
                            iconTint: DesignSystem.Colors.coral,
                            title: "Cost Threshold",
                            subtitle: "Highlight unusually expensive days before spend drifts upward",
                            value: settingsManager.costAlertThreshold == nil
                                ? "Off"
                                : "$\(settingsManager.costAlertThreshold!.formatted(.number.precision(.fractionLength(0...2))))",
                            valueTint: settingsManager.costAlertThreshold == nil
                                ? DesignSystem.Colors.textMuted
                                : DesignSystem.Colors.success
                        )
                    }
                    .settingsAnchor(SettingsAnchor.alertsDailySpend)
                } header: {
                    Text("Spend alerts")
                } footer: {
                    Text("OpenBurnBar evaluates spend locally; nothing here is sent to a server.")
                        .font(DesignSystem.Typography.tiny)
                }

                Section {
                    NavigationLink {
                        DailyDigestDetailView(settingsManager: settingsManager)
                    } label: {
                        SettingsDrillRow(
                            icon: "newspaper.fill",
                            iconTint: DesignSystem.Colors.amber,
                            title: "Daily Digest",
                            subtitle: "One compact reality check at a fixed local time",
                            value: settingsManager.dailyDigestEnabled
                                ? String(format: "%02d:00", settingsManager.dailyDigestHour)
                                : "Off",
                            valueTint: settingsManager.dailyDigestEnabled
                                ? DesignSystem.Colors.success
                                : DesignSystem.Colors.textMuted
                        )
                    }
                    .settingsAnchor(SettingsAnchor.alertsDigest)
                } header: {
                    Text("Digest")
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("Alerts")
    }
}

// MARK: - Spend Alert Detail

struct SpendAlertDetailView: View {
    @Bindable var settingsManager: SettingsManager
    let costAlertBinding: Binding<Double>

    var body: some View {
        SettingsDetailContainer(
            title: "Cost Threshold",
            subtitle: "Warn when estimated daily burn crosses an amount you choose."
        ) {
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
        }
    }
}

// MARK: - Daily Digest Detail

struct DailyDigestDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Daily Digest",
            subtitle: "Get one compact reality check instead of finding out at month end."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Daily digest",
                        subtitle: "Receive a once-daily summary of yesterday's burn.",
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
    }
}

// MARK: - Notifications Settings View (iOS-style landing)

struct NotificationsSettingsView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .notificationsRoot) { _ in
            List {
                Section {
                    NavigationLink {
                        LocalNotificationsDetailView(settingsManager: settingsManager)
                    } label: {
                        SettingsDrillRow(
                            icon: "app.badge.fill",
                            iconTint: DesignSystem.Colors.whimsy,
                            title: "Local Notifications",
                            subtitle: "Controller can nudge you on this Mac about followups and pending work",
                            value: settingsManager.controllerLocalNotificationsEnabled ? "On" : "Off",
                            valueTint: settingsManager.controllerLocalNotificationsEnabled
                                ? DesignSystem.Colors.success
                                : DesignSystem.Colors.textMuted
                        )
                    }
                    .settingsAnchor(SettingsAnchor.notificationsLocal)
                } header: {
                    Text("On this Mac")
                }

                Section {
                    NavigationLink {
                        TelegramBridgeDetailView(settingsManager: settingsManager)
                    } label: {
                        SettingsDrillRow(
                            icon: "paperplane.fill",
                            iconTint: DesignSystem.Colors.teal,
                            title: "Telegram Bridge",
                            subtitle: "Followup delivery and commands through a Telegram bot",
                            value: settingsManager.controllerTelegramEnabled ? "On" : "Off",
                            valueTint: settingsManager.controllerTelegramEnabled
                                ? DesignSystem.Colors.success
                                : DesignSystem.Colors.textMuted
                        )
                    }
                    .settingsAnchor(SettingsAnchor.notificationsTelegram)

                    NavigationLink {
                        CalendarIntegrationDetailView(settingsManager: settingsManager)
                    } label: {
                        SettingsDrillRow(
                            icon: "calendar",
                            iconTint: DesignSystem.Colors.coral,
                            title: "Calendar Integration",
                            subtitle: "Block local calendar placeholders for scheduled followups",
                            value: settingsManager.controllerCalendarIntegrationEnabled
                                ? "\(settingsManager.controllerCalendarDefaultMinutes) min"
                                : "Off",
                            valueTint: settingsManager.controllerCalendarIntegrationEnabled
                                ? DesignSystem.Colors.success
                                : DesignSystem.Colors.textMuted
                        )
                    }
                    .settingsAnchor(SettingsAnchor.notificationsCalendar)

                    NavigationLink {
                        SnoozeDefaultsDetailView(settingsManager: settingsManager)
                    } label: {
                        SettingsDrillRow(
                            icon: "clock.arrow.circlepath",
                            iconTint: DesignSystem.Colors.amber,
                            title: "Snooze Defaults",
                            subtitle: "Default snooze window applied to new or deferred followups",
                            value: "\(settingsManager.controllerDefaultSnoozeMinutes) min"
                        )
                    }
                } header: {
                    Text("Controller channels")
                } footer: {
                    Text("Telegram credentials are stored locally and only used to send your own bot messages.")
                        .font(DesignSystem.Typography.tiny)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("Notifications")
    }
}

// MARK: - Local Notifications Detail

struct LocalNotificationsDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Local Notifications",
            subtitle: "Use macOS local notifications for daemon-backed reminders and followups."
        ) {
            GlassCard {
                SettingsToggle(
                    title: "Controller local notifications",
                    subtitle: "Allow the daemon-backed runtime to nudge you about followups and pending work on this Mac.",
                    icon: "app.badge",
                    isOn: $settingsManager.controllerLocalNotificationsEnabled
                )
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Telegram Bridge Detail

struct TelegramBridgeDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Telegram Bridge",
            subtitle: "Enable Telegram commands and followup delivery when a bot token and chat ID are configured."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Telegram bridge",
                        subtitle: settingsManager.controllerTelegramEnabled
                            ? "Token and chat ID below are used for outbound messages."
                            : "Add your bot token and chat ID to enable.",
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
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Calendar Integration Detail

struct CalendarIntegrationDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Calendar Integration",
            subtitle: "Create local calendar placeholders for scheduled followups."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Calendar integration",
                        subtitle: "Reserve time on your calendar when followups are scheduled.",
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
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Snooze Defaults Detail

struct SnoozeDefaultsDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Snooze Defaults",
            subtitle: "How long OpenBurnBar waits when you snooze or defer a followup."
        ) {
            GlassCard {
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
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}
