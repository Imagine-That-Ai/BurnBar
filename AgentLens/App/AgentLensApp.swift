import AppKit
import FirebaseCore
import GoogleSignIn
import SwiftUI

// MARK: - Window Manager

@MainActor
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func openDashboard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = dashboardWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = DashboardView(
            dataStore: dataStore,
            aggregator: aggregator,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService
        )
        .frame(minWidth: 900, minHeight: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = BurnBarIdentity.productName
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(DesignSystem.Colors.background)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        dashboardWindow = window
    }

    func openSettings(
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        dataStore: DataStore
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsView(
            settingsManager: settingsManager,
            accountManager: accountManager,
            cloudSyncService: cloudSyncService,
            dataStore: dataStore
        )
        .frame(width: 600, height: 540)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        settingsWindow = window
    }
}

// MARK: - App Entry Point

@main
struct BurnBarApp: App {
    private static var didConfigureFirebase = false

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("hasShownInitialDashboard") private var hasShownInitialDashboard = false
    @StateObject private var windowManager = WindowManager.shared
    @State private var dataStore: DataStore
    @State private var settingsManager: SettingsManager
    @State private var aggregator: UsageAggregator?
    @State private var accountManager: AccountManager
    @State private var cloudSyncService: CloudSyncService?

    @MainActor
    init() {
        Self.configureFirebaseIfAvailable()
        BurnBarMigration.migrateUserDefaults()
        _ = try? BurnBarMigration.prepareSupportDirectory()
        _dataStore = State(initialValue: DataStore())
        _settingsManager = State(initialValue: SettingsManager.shared)
        _aggregator = State(initialValue: nil)
        _accountManager = State(initialValue: AccountManager.shared)
        _cloudSyncService = State(initialValue: nil)
    }

    @MainActor
    private static func configureFirebaseIfAvailable() {
        guard !didConfigureFirebase else {
            AccountManager.shared.onFirebaseConfigured()
            return
        }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            return
        }
        FirebaseApp.configure(options: options)
        didConfigureFirebase = true
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        AccountManager.shared.onFirebaseConfigured()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(
                dataStore: dataStore,
                aggregator: aggregator,
                settingsManager: settingsManager,
                onOpenDashboard: {
                    windowManager.openDashboard(
                        dataStore: dataStore,
                        aggregator: aggregator,
                        accountManager: accountManager,
                        cloudSyncService: cloudSyncService
                    )
                },
                onOpenSettings: {
                    windowManager.openSettings(
                        settingsManager: settingsManager,
                        accountManager: accountManager,
                        cloudSyncService: cloudSyncService,
                        dataStore: dataStore
                    )
                }
            )
        } label: {
            MenuBarLabel(
                totalCostToday: dataStore.totalCostToday,
                totalTokensToday: dataStore.totalTokensToday,
                usageDisplayMode: settingsManager.usageDisplayMode,
                rollingDailyAverage: dataStore.rollingDailyAverage,
                isRefreshing: aggregator?.isRefreshing ?? false
            )
            .task {
                guard aggregator == nil else { return }
                let sync = CloudSyncService(dataStore: dataStore, accountManager: accountManager)
                cloudSyncService = sync
                let newAggregator = UsageAggregator(dataStore: dataStore, cloudSync: sync)
                aggregator = newAggregator
                CursorConnectorManager.shared.attach(dataStore: dataStore)
                if !hasShownInitialDashboard {
                    hasShownInitialDashboard = true
                    windowManager.openDashboard(
                        dataStore: dataStore,
                        aggregator: newAggregator,
                        accountManager: accountManager,
                        cloudSyncService: sync
                    )
                }
                // Don’t block the first frame on a long disk scan; the menu bar can appear while refresh runs.
                Task(priority: .userInitiated) {
                    await newAggregator.refreshAll()
                    await sync.uploadPendingConversations()
                    if settingsManager.dailyDigestEnabled {
                        await DailyDigestManager.shared.requestAuthorization()
                        DailyDigestManager.shared.scheduleDigest(from: dataStore, at: settingsManager.dailyDigestHour)
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let totalCostToday: Double
    let totalTokensToday: Int
    let usageDisplayMode: UsageDisplayMode
    let rollingDailyAverage: Double
    let isRefreshing: Bool

    @State private var showCostIncrease = false
    @State private var bounceTick = 0
    @State private var logoBounceScale: CGFloat = 1
    @State private var pulseGlow: CGFloat = 0
    @AppStorage("lastDailyCostPulseDay") private var lastDailyCostPulseDay: String = ""

    /// Shown on hover in the menu bar (balance for the selected display mode).
    private var balanceTooltip: String {
        switch usageDisplayMode {
        case .currency:
            return "Today: \(totalCostToday.formatAsCost())"
        case .tokens:
            return "Today: \(totalTokensToday.formatAsTokenVolume()) tokens"
        }
    }

    private var todayDayKey: String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var shouldDailyPulse: Bool {
        rollingDailyAverage > 0 && totalCostToday > rollingDailyAverage * 1.2
    }

    private var menuBarIcon: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 10, height: 13)
            .foregroundStyle(Color.primary)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            menuBarIcon
                .scaleEffect(logoBounceScale)
                .shadow(color: Color.primary.opacity(pulseGlow * 0.35), radius: pulseGlow * 3)

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.5)
                    .offset(x: 3, y: -3)
            } else if showCostIncrease {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.green)
                    .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                    .offset(x: 3, y: -2)
                    .transition(.opacity)
            }
        }
        .help(balanceTooltip)
        .accessibilityLabel("\(BurnBarIdentity.productName), \(balanceTooltip)")
        .onChange(of: isRefreshing) { _, new in
            if !new {
                bounceTick &+= 1
            }
        }
        .onChange(of: bounceTick) { _, _ in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                logoBounceScale = 1.14
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    logoBounceScale = 1
                }
            }
        }
        .onChange(of: totalCostToday) { oldValue, newValue in
            guard newValue > oldValue, oldValue > 0 else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                showCostIncrease = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showCostIncrease = false
                }
            }
        }
        .onChange(of: shouldDailyPulse) { _, pulse in
            guard pulse, lastDailyCostPulseDay != todayDayKey else { return }
            lastDailyCostPulseDay = todayDayKey
            pulseGlow = 0
            withAnimation(.easeInOut(duration: 0.45)) {
                pulseGlow = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.6)) {
                    pulseGlow = 0
                }
            }
        }
    }
}
