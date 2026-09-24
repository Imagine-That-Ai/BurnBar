import CoreGraphics
import Foundation
import OpenBurnBarInboxModels
import OpenBurnBarKernel

/// Pure iPad command-desk navigation rules.
///
/// Regular-width iPad is a desk, not a large phone: Inbox launches, Agents
/// keep the sidebar, Watch is an inspector plus an optional Stage Manager
/// window, and Insights is reachable (`ShowInsightsTab` must actually
/// select it). Compact iPad stays on `RootTabView`.
enum IPadAwayDeskNavigation {
    static let launchDestination: AppDestination = .inbox

    /// Primary scene identity. Stage Manager must not clone this into a
    /// second Inbox desk — extra windows are Watch only.
    static let deskWindowID = "desk"

    /// Stage Manager extra scene. Watch only — never a second Inbox desk.
    /// `Window(id:)` is macOS/visionOS; iPad uses `WindowGroup(id:)`.
    static let watchWindowID = "agent-watch"

    /// Extra Stage Manager windows are Watch, never another desk.
    static let extraWindowIsWatchOnly = true

    /// Sidebar primaries. Order is the away-from-desk job, not Pulse-first history.
    static let defaultPrimaryDestinations: [AppDestination] = [
        .inbox, .agents, .burn, .you
    ]

    static let defaultSecondaryDestinations: [AppDestination] = [
        .providers, .devices, .settings
    ]

    /// Pre-desk default written by older builds. Treat as unset so Inbox becomes home.
    static let legacyPrimaryDestinations: [AppDestination] = [
        .pulse, .burn, .insights, .streams, .agents
    ]

    static let youLabel = "You"

    enum ColumnMode: Equatable {
        /// Three-closure split: destinations | decision rail | canvas.
        case threeColumn
        /// Two-closure split: destinations | canvas. Not `Visibility.doubleColumn`
        /// (that hides the destination sidebar on a three-column split).
        case twoColumn
    }

    static func columnMode(for destination: AppDestination) -> ColumnMode {
        switch destination {
        case .inbox, .agents, .burn, .you:
            return .threeColumn
        default:
            return .twoColumn
        }
    }

    /// App-wide `.searchable` on the root split. Inbox and Agents are the
    /// rails that consume the query; Quota / You filter their grouped lists.
    static func usesAppWideSearch(for destination: AppDestination) -> Bool {
        switch destination {
        case .inbox, .agents, .burn, .you:
            return true
        default:
            return false
        }
    }

    static func searchPrompt(for destination: AppDestination) -> String {
        switch destination {
        case .inbox: return "Search inbox"
        case .agents: return "Search agents"
        case .burn: return "Search quota"
        case .you: return "Search You"
        default: return "Search"
        }
    }

    /// You decision-rail groups. Keep-awake is a first-class host control.
    enum YouGroup: String, CaseIterable, Identifiable, Equatable {
        case pairing
        case keepAwake
        case devices
        case cloud
        case appearance
        case dataVault
        case labs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pairing: return "Pairing"
            case .keepAwake: return "Keep Mac awake"
            case .devices: return "Devices"
            case .cloud: return "Cloud"
            case .appearance: return "Appearance"
            case .dataVault: return "Data Vault"
            case .labs: return "Labs"
            }
        }

        var systemImage: String {
            switch self {
            case .pairing: return "link"
            case .keepAwake: return "sun.max.fill"
            case .devices: return "ipad.and.iphone"
            case .cloud: return "cloud.fill"
            case .appearance: return "paintbrush.fill"
            case .dataVault: return "lock.square.stack.fill"
            case .labs: return "flask.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .pairing: return "iroh pairing and Hermes gateway"
            case .keepAwake: return "Stay a host while you are away"
            case .devices: return "This iPad and paired hosts"
            case .cloud: return "Membership and hosted quota"
            case .appearance: return "Theme and backdrop"
            case .dataVault: return "Private memory and privacy inventory"
            case .labs: return "Pulse, Insights, Streams, Recap"
            }
        }
    }

    static func filteredYouGroups(_ query: String) -> [YouGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return YouGroup.allCases }
        return YouGroup.allCases.filter { group in
            group.title.localizedCaseInsensitiveContains(needle)
                || group.subtitle.localizedCaseInsensitiveContains(needle)
                || group.rawValue.localizedCaseInsensitiveContains(needle)
        }
    }

    static func filteredProviderKeys(_ keys: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return keys }
        return keys.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// Pointer secondary-click verbs on Inbox rows. Approve is the item's
    /// primary next step — memory quarantine still happens on the Mac.
    enum InboxPointerAction: String, CaseIterable, Equatable {
        case approve
        case openThread
        case archive
        case snooze
        case copyLink

        var title: String {
            switch self {
            case .approve: return "Approve"
            case .openThread: return "Open thread"
            case .archive: return "Archive"
            case .snooze: return "Snooze"
            case .copyLink: return "Copy link"
            }
        }
    }

    static func inboxPointerActions() -> [InboxPointerAction] {
        InboxPointerAction.allCases
    }

    static func inboxItemLink(itemID: String) -> URL? {
        AIInboxDeepLink.url(itemID: itemID)
    }

    static func inboxOpenThreadValue(payload: BurnBarInboxItemPayload) -> String? {
        if let resume = payload.actions.first(where: { $0.kind == .resumeConversation }) {
            let value = resume.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let url = payload.evidence.first(where: { $0.kind == .conversation })?.url {
            let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func inboxPrimaryAction(payload: BurnBarInboxItemPayload) -> BurnBarInboxAction? {
        payload.actions.first(where: \.isPrimary) ?? payload.actions.first
    }

    /// Agents must not hide the destination sidebar (the old `.detailOnly` habit).
    static func hidesDestinationSidebar(for destination: AppDestination) -> Bool {
        false
    }

    static func destination(forCommandNumber number: Int) -> AppDestination? {
        switch number {
        case 1: return .inbox
        case 2: return .agents
        case 3: return .burn
        case 4: return .you
        default: return nil
        }
    }

    /// `ShowInsightsTab` / `InsightsDeepLink` selects Insights itself — not Pulse, not You.
    static func destinationAfterInsightsDeepLink() -> AppDestination {
        .insights
    }

    /// Agent Watch / Mercury pin the inspector or open the Watch window.
    /// They do not steal the sidebar selection.
    static func destinationAfterPinningWatch(current: AppDestination) -> AppDestination {
        current
    }

    /// Hardware chords for the Session / Window menus.
    /// ⌘. Halt and ⌃⌥⌘. panic share the signed halt envelope (Mac panic path).
    enum HardwareChord: String, Equatable {
        case halt
        case panic
        case openWatchWindow
    }

    static func hardwareChord(
        key: Character,
        command: Bool,
        control: Bool,
        option: Bool,
        shift: Bool
    ) -> HardwareChord? {
        if key == ".", command, control, option, !shift {
            return .panic
        }
        if key == ".", command, !control, !option, !shift {
            return .halt
        }
        if key == "w" || key == "W", command, option, !control, !shift {
            return .openWatchWindow
        }
        return nil
    }

    /// Empty or Pulse-first saved sidebars become the Inbox-first desk.
    static func resolvedPrimaryDestinations(_ stored: [AppDestination]?) -> [AppDestination] {
        guard let stored, !stored.isEmpty else {
            return defaultPrimaryDestinations
        }
        if stored == legacyPrimaryDestinations {
            return defaultPrimaryDestinations
        }
        return stored
    }

    static func resolvedSecondaryDestinations(
        _ stored: [AppDestination]?,
        primary: [AppDestination]
    ) -> [AppDestination] {
        let decoded: [AppDestination]
        if let stored, !stored.isEmpty {
            decoded = stored
        } else {
            decoded = defaultSecondaryDestinations
        }
        let blocked = Set(primary)
        return decoded.filter { !blocked.contains($0) }
    }

    // MARK: - Two pointers (Watch inspector + Mercury pane)

    /// Local iPadOS finger-dot hits chrome. The Mac arrow is only drawn
    /// on a live HEVC/stream canvas.
    enum PointerRegion: String, Equatable {
        case localChrome
        case hostPixels
    }

    /// Watch canvas is live pixels, an honest empty, or a labeled still.
    /// Never a wallpaper pretending to be video.
    enum PixelPresentation: String, Equatable {
        case live
        case honestEmpty
        case labeledStill
    }

    enum DriveChord: String, Equatable {
        case space
        case escape
        case doubleClick
    }

    /// Halt stays on-screen for the whole inspector lifetime.
    static let haltAlwaysVisible = true

    /// Pill on first input and again after this lull (same rule as maximize).
    static let drivingPillLullSeconds: TimeInterval = 4

    /// Hide the pill shortly after input so chrome yields to the host.
    static let drivingPillRecentInputSeconds: TimeInterval = 1.5

    static let haltAccessibilityID = "ipad.watch.halt"
    static let pixelsAccessibilityID = "ipad.watch.pixels"
    static let mercuryAccessibilityID = "ipad.watch.mercury"
    static let mercuryEmptyAccessibilityID = "ipad.watch.mercury.empty"
    static let askToMirrorAccessibilityID = "ipad.watch.askToMirror"
    static let hostCursorAccessibilityID = "ipad.watch.hostCursor"
    static let drivePillAccessibilityID = "ipad.watch.drivePill"
    static let mouseLockedAccessibilityID = "ipad.watch.mouseLocked"

    static func pixelPresentation(hasLiveFrame: Bool, isLabeledStill: Bool) -> PixelPresentation {
        if hasLiveFrame { return .live }
        if isLabeledStill { return .labeledStill }
        return .honestEmpty
    }

    /// iPadOS hover/lift is chrome-only. Outer `.hoverEffectDisabled` on
    /// the live pixel pane wins so a Mac cursor is not painted on Halt /
    /// Ask to Mirror.
    static func disablesHover(_ region: PointerRegion, presentation: PixelPresentation) -> Bool {
        region == .hostPixels && presentation == .live
    }

    /// Magnetism belongs on highlight/lift chrome, never the stream.
    static func usesMagnetism(_ region: PointerRegion) -> Bool {
        region == .localChrome
    }

    /// Draw the host arrow only when the decoder has a frame *and* a
    /// cursor sample. Touch mode does not invent a fake iPad arrow.
    static func shouldDrawHostCursor(
        presentation: PixelPresentation,
        hasCursorSample: Bool
    ) -> Bool {
        presentation == .live && hasCursorSample
    }

    static func canEnterDriveMode(hasLiveFrame: Bool) -> Bool {
        hasLiveFrame
    }

    /// Space / double-click enter drive only on live pixels. Esc leaves
    /// and never Halts.
    static func driveMode(
        current _: Bool,
        chord: DriveChord,
        hasLiveFrame: Bool
    ) -> Bool {
        switch chord {
        case .space, .doubleClick:
            return hasLiveFrame
        case .escape:
            return false
        }
    }

    static func isDrivingPillVisible(
        isDriving: Bool,
        lastInputAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard isDriving else { return false }
        guard let lastInputAt else { return true }
        let age = now.timeIntervalSince(lastInputAt)
        return age < drivingPillRecentInputSeconds || age >= drivingPillLullSeconds
    }

    /// Maps a host cursor sample onto a local canvas.
    ///
    /// `MediaFrame` intentionally carries only codec payload + cursor
    /// metadata. Until the stream publishes source dimensions, normalize
    /// against the common Mercury screen-share canvas so the cursor remains
    /// visible and directionally correct instead of clipping off-screen.
    static func hostCursorPoint(
        x: Int16,
        y: Int16,
        in size: CGSize,
        frameWidth: CGFloat = 1920,
        frameHeight: CGFloat = 1080
    ) -> CGPoint {
        guard frameWidth > 0, frameHeight > 0, size.width > 0, size.height > 0 else {
            return .zero
        }
        let nx = min(max(CGFloat(x) / frameWidth, 0), 1)
        let ny = min(max(CGFloat(y) / frameHeight, 0), 1)
        return CGPoint(x: nx * size.width, y: ny * size.height)
    }

    static func mouseLockedCopy(isDriving: Bool) -> String? {
        isDriving ? "Mouse on Mac · Esc releases" : nil
    }
}

extension AppDestination {
    /// Hardware-keyboard View-menu index. `nil` means reachable, not a ⌘N primary.
    var iPadCommandNumber: Int? {
        switch self {
        case .inbox: return 1
        case .agents: return 2
        case .burn: return 3
        case .you: return 4
        default: return nil
        }
    }
}
