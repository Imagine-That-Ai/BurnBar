import SwiftUI

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        TabView {
            GeneralSettingsView(settingsManager: settingsManager)
                .tabItem {
                    Label("General", systemImage: "gearshape.fill")
                }
            
            ProvidersSettingsView(settingsManager: settingsManager)
                .tabItem {
                    Label("Providers", systemImage: "externaldrive.connected.to.line.below")
                }
            
            AlertsSettingsView(settingsManager: settingsManager)
                .tabItem {
                    Label("Alerts", systemImage: "bell.fill")
                }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section("Application") {
                Toggle("Show in Menu Bar", isOn: $settingsManager.showInMenuBar)
                Toggle("Launch at Login", isOn: $settingsManager.launchAtLogin)
            }
            
            Section("Data Refresh") {
                HStack {
                    Text("Refresh Interval")
                    Spacer()
                    Picker("", selection: $settingsManager.refreshInterval) {
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("15 minutes").tag(TimeInterval(900))
                    }
                    .frame(width: 120)
                }
            }
            
            Section("Default View") {
                Picker("Time Range", selection: $settingsManager.defaultTimeRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Providers Settings

private struct ProvidersSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section {
                Text("Configure log file paths for each provider. Leave empty to use defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            ForEach(AgentProvider.allCases) { provider in
                Section(provider.displayName) {
                    HStack {
                        Text("Log Path")
                            .frame(width: 80, alignment: .leading)
                        
                        TextField(
                            "Path",
                            text: Binding(
                                get: { settingsManager.logPaths[provider] ?? provider.logDirectory },
                                set: { settingsManager.logPaths[provider] = $0.isEmpty ? provider.logDirectory : $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            // Open file dialog
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            
                            if panel.runModal() == .OK, let url = panel.url {
                                settingsManager.logPaths[provider] = url.path
                            }
                        }
                    }
                    
                    HStack {
                        Text("Default")
                            .frame(width: 80, alignment: .leading)
                        Text(provider.logDirectory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Alerts Settings

private struct AlertsSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @State private var alertEnabled: Bool = false
    @State private var alertThreshold: Double = 10.0
    
    var body: some View {
        Form {
            Section("Daily Cost Alert") {
                Toggle("Enable Alert", isOn: $alertEnabled)
                    .onChange(of: alertEnabled) { _, newValue in
                        if newValue {
                            settingsManager.costAlertThreshold = alertThreshold
                        } else {
                            settingsManager.costAlertThreshold = nil
                        }
                    }
                
                if alertEnabled {
                    HStack {
                        Text("Alert when daily cost exceeds")
                        Spacer()
                        TextField("", value: $alertThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: alertThreshold) { _, newValue in
                                settingsManager.costAlertThreshold = newValue
                            }
                        Text("USD")
                    }
                    
                    Text("You'll receive a notification when your daily spending exceeds this threshold.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Budget Tracking") {
                Text("Set up alerts to monitor your spending and stay within budget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            alertEnabled = settingsManager.costAlertThreshold != nil
            alertThreshold = settingsManager.costAlertThreshold ?? 10.0
        }
    }
}

#Preview {
    SettingsView(settingsManager: SettingsManager.shared)
}
