import SwiftUI

@main
struct AgentLensApp: App {
    @State private var dataStore: DataStore
    @State private var settingsManager: SettingsManager
    @Environment(\.openWindow) private var openWindow

    init() {
        let store = DataStore()
        _dataStore = State(initialValue: store)
        _settingsManager = State(initialValue: SettingsManager.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(
                dataStore: dataStore,
                onOpenDashboard: { openWindow(id: "dashboard") },
                onOpenSettings: { openWindow(id: "settings") }
            )
        } label: {
            MenuBarLabelView(totalCostToday: dataStore.totalCostToday)
        }
        .menuBarExtraStyle(.window)

        Window("AgentLens Dashboard", id: "dashboard") {
            DashboardView(dataStore: dataStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 750)

        Settings {
            SettingsView(settingsManager: settingsManager)
                .frame(width: 500, height: 400)
        }
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabelView: View {
    let totalCostToday: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .semibold))
            Text(formatCost(totalCostToday))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1.0 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}
