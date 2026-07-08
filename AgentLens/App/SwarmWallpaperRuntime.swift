import AppKit
import OpenBurnBarCore
import QuartzCore
import SwiftUI

// Extracted verbatim from AppDelegate.swift (audit wave 4, item 14).
// The dynamic swarm wallpaper runtime: color-driver builder, the reactive
// view model, the SwiftUI canvas wrapper, and the click-through NSPanel
// that hosts it behind the desktop icons.

// MARK: - Dynamic Swarm Wallpaper Types

enum SwarmWallpaperColorDriverBuilder {
    static func driver(
        totalCostToday: Double,
        providerSummaries: [ProviderSummary],
        agentStatuses: [String: PixelClockAgentStatus],
        daemonIsBusy: Bool
    ) -> SwarmColorDriver {
        let runningProviders = runningProviders(from: agentStatuses)
        let mode: SwarmColorDriver.Mode = daemonIsBusy || !runningProviders.isEmpty ? .active : .idle
        let weights = runningProviders.isEmpty
            ? historicalWeights(from: providerSummaries, totalCostToday: totalCostToday)
            : activeWeights(from: runningProviders)

        return SwarmColorDriver(
            mode: mode,
            providers: weights,
            totalBurnRateUSD: totalCostToday
        )
    }

    static func runningProviders(from statuses: [String: PixelClockAgentStatus]) -> [AgentProvider] {
        let providers = statuses.compactMap { entry -> AgentProvider? in
            let (key, status) = entry
            guard status == .running else { return nil }
            return provider(forStatusToken: key)
        }

        var seen: Set<AgentProvider> = []
        return providers
            .filter { seen.insert($0).inserted }
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func provider(forStatusToken token: String) -> AgentProvider? {
        let normalized = normalizedProviderToken(token)
        let aliases: [String: AgentProvider] = [
            "anthropic": .claudeCode,
            "claude": .claudeCode,
            "claudecode": .claudeCode,
            "claudecli": .claudeCode,
            "codex": .codex,
            "openai": .openAI,
            "openaicodex": .codex,
            "opencode": .openCode,
            "openclaw": .openClaw,
            "factory": .factory,
            "droid": .factory,
            "cursor": .cursor,
            "xai": .xAI,
            "grok": .xAI,
            "supergrok": .xAI
        ]
        if let alias = aliases[normalized] {
            return alias
        }

        return AgentProvider.allCases.first { provider in
            normalized == normalizedProviderToken(provider.rawValue)
                || normalized == normalizedProviderToken(provider.persistedToken)
                || normalized == normalizedProviderToken(provider.providerID.rawValue)
        }
    }

    private static func activeWeights(from providers: [AgentProvider]) -> [SwarmColorDriver.ProviderWeight] {
        guard !providers.isEmpty else { return [] }
        let weight = 1.0 / Double(providers.count)
        return providers.map { provider in
            SwarmColorDriver.ProviderWeight(provider: provider, weight: weight, quotaPressure: 0)
        }
    }

    private static func historicalWeights(
        from providerSummaries: [ProviderSummary],
        totalCostToday: Double
    ) -> [SwarmColorDriver.ProviderWeight] {
        guard !providerSummaries.isEmpty else { return [] }

        let weights: [SwarmColorDriver.ProviderWeight]
        if totalCostToday > 0 {
            weights = providerSummaries.map { summary in
                SwarmColorDriver.ProviderWeight(
                    provider: summary.provider,
                    weight: summary.totalCost / totalCostToday,
                    quotaPressure: 0
                )
            }
        } else {
            let totalTokens = providerSummaries.reduce(0) { $0 + $1.totalTokens }
            if totalTokens > 0 {
                weights = providerSummaries.map { summary in
                    SwarmColorDriver.ProviderWeight(
                        provider: summary.provider,
                        weight: Double(summary.totalTokens) / Double(totalTokens),
                        quotaPressure: 0
                    )
                }
            } else {
                let equalWeight = 1.0 / Double(providerSummaries.count)
                weights = providerSummaries.map { summary in
                    SwarmColorDriver.ProviderWeight(
                        provider: summary.provider,
                        weight: equalWeight,
                        quotaPressure: 0
                    )
                }
            }
        }

        return weights.sorted { lhs, rhs in
            if lhs.weight == rhs.weight {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            return lhs.weight > rhs.weight
        }
    }

    private static func normalizedProviderToken(_ token: String) -> String {
        token
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Reactive view model for coordinating the live background state.
@Observable
@MainActor
public final class SwarmWallpaperViewModel {
    public var pointer: CGPoint?
    public var colorDriver: SwarmColorDriver?
    public var isBatteryThrottled: Bool = false
    public var isPaused: Bool = false
    var background: DesktopWallpaperBackground = .macOSDesktop
    var speed: Double = 1.0
    var providerGlyphs: [AgentProvider] = SwarmProviderGlyphSelection.allProviders
    var autoCyclesShapes: Bool = true
    var allowsDesktopClickCycle: Bool = false
    var enableSwarmSparkles: Bool = true
    var excludeBrandShapesFromSwarm: Bool = false

    public init() {}

    func apply(appearance: AppearanceSettings) {
        background = appearance.desktopWallpaperBackground
        speed = appearance.desktopWallpaperSpeed
        providerGlyphs = appearance.desktopWallpaperProviderGlyphs
        autoCyclesShapes = appearance.cycleShapesScreensaver
        allowsDesktopClickCycle = appearance.clickDesktopToCycleSwarm
        enableSwarmSparkles = appearance.enableSwarmSparkles
        excludeBrandShapesFromSwarm = appearance.excludeBrandShapesFromSwarm
    }
}

/// SwiftUI wrapper for displaying the SwarmCanvasView within the wallpaper panel.
struct SwarmWallpaperView: View {
    let viewModel: SwarmWallpaperViewModel
    @StateObject private var substrateBox = SwarmSubstrateBox()
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = SubstrateCatalog.plainID
    @AppStorage(SwarmSubstratePreferences.backdropKernelKey) private var backdropKernel: String = SwarmSubstratePreferences.defaultKernelID

    private var substrate: SwarmSubstrate {
        substrateBox.resolve(kernelID: backdropKernel, selectedID: substrateID, enabled: substrateEnabled)
    }

    var body: some View {
        let background = viewModel.background
        let speed = viewModel.speed
        let providerGlyphs = viewModel.providerGlyphs
        let autoCyclesShapes = viewModel.autoCyclesShapes
        let enableSparkles = viewModel.enableSwarmSparkles
        let excludeBrandShapes = viewModel.excludeBrandShapesFromSwarm

        SwarmCanvasView(
            accent: .purple,
            pace: .cinematic, // Cinematic pace is perfect for ambient wallpaper
            colorDriver: viewModel.colorDriver,
            isBatteryThrottled: viewModel.isBatteryThrottled,
            externalPointer: viewModel.pointer,
            isTransparent: false,
            backdropColor: background.isTransparent ? nil : background.swatchColor,
            backdropColors: background.swatchPreviewColors,
            colorPalette: background.swarmPalette,
            motionSpeedMultiplier: speed,
            isAutoCyclingEnabled: autoCyclesShapes,
            enabledProviderGlyphs: providerGlyphs,
            enableSwarmSparkles: enableSparkles,
            excludeBrandShapesFromSwarm: excludeBrandShapes || !providerGlyphs.isEmpty,
            // The wallpaper is an ambient surface that sits behind every
            // window and icon — capping at 30 fps + rendering the Canvas
            // asynchronously halves CPU work with no perceptible change in
            // the ambient field.
            maxFrameRate: 30.0,
            rendersAsynchronously: true,
            substrate: substrate
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.18), value: background)
        .animation(.easeInOut(duration: 0.18), value: speed)
        .animation(.easeInOut(duration: 0.18), value: providerGlyphs)
        .animation(.easeInOut(duration: 0.18), value: autoCyclesShapes)
    }
}

/// A stationary, click-through transparent NSPanel floating behind desktop folders and icons
/// that hosts the dynamic AI usage ember swarm simulation.
public class BurnBarWallpaperPanel: NSPanel {
    private nonisolated(unsafe) var mouseMonitor: Any?
    private nonisolated(unsafe) var clickMonitor: Any?
    private let viewModel: SwarmWallpaperViewModel
    private let targetScreen: NSScreen

    /// Last pointer position written to the view-model. We coalesce raw HID
    /// events through a 30 Hz throttle (`pointerCommitInterval`) and a 4 pt
    /// movement gate, so micro-jitter no longer causes 60–120 `@Observable`
    /// writes per second — at idle desktop usage the pointer pipeline is now
    /// essentially zero-cost.
    private var lastCommittedPointer: CGPoint?
    private var pendingPointer: CGPoint?
    private var lastPointerCommitTime: TimeInterval = 0
    private nonisolated(unsafe) var pointerCoalesceTimer: DispatchSourceTimer?
    private static let pointerCommitInterval: TimeInterval = 1.0 / 30.0
    private static let pointerMovementThreshold: CGFloat = 4.0

    public init(screen: NSScreen, viewModel: SwarmWallpaperViewModel) {
        self.viewModel = viewModel
        self.targetScreen = screen

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = false
        // Place exactly under desktop icons, but above standard background image
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        self.collectionBehavior = [
            .canJoinAllSpaces,   // Live on all virtual desktops (Spaces)
            .ignoresCycle,       // Exclude from Cmd+` cycle list
            .stationary,         // Stay visually pinned during Space transitions
            .fullScreenAuxiliary // Keep the panel available while fullscreen Spaces are active
        ]

        self.ignoresMouseEvents = true // Make click-through so user can interact with files
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.canHide = false
        self.animationBehavior = .none
        self.isReleasedWhenClosed = false

        let swarmView = SwarmWallpaperView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: swarmView)
        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView

        // Global mouse tracking monitor to feed cursor position to the canvas without window focus.
        // We coalesce raw events through `enqueuePointerSample` so the
        // `@Observable` view-model is written at most ~30 times/sec instead
        // of at the raw HID rate (≥ 60 Hz on macOS).
        self.mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, !self.viewModel.isPaused else { return }
            let globalPoint = NSEvent.mouseLocation

            if self.targetScreen.frame.contains(globalPoint) {
                let localPoint = self.convertScreenPointToLocal(globalPoint)
                self.enqueuePointerSample(localPoint)
            } else {
                self.enqueuePointerSample(nil)
            }
        }

        // Global mouse click tracking to cycle swarm when clicking on the desktop background.
        // Finder becomes frontmost after the click is dispatched, so validation is deferred.
        self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.scheduleDesktopClickCycleIfNeeded()
        }
    }

    /// Coalesces raw HID-rate pointer events into a 30 Hz commit stream with
    /// a sub-threshold movement gate. The visible swarm consumes pointer
    /// position only at frame boundaries, so committing 60+ times/sec is
    /// pure waste — at the new cadence the field tracks the cursor within
    /// one frame visually while paying ½× to ¼× the `@Observable` write
    /// cost.
    private func enqueuePointerSample(_ point: CGPoint?) {
        // `nil` means the cursor left the screen — commit immediately so the
        // swarm doesn't keep pushing against a stale phantom pointer.
        if point == nil {
            pendingPointer = nil
            commitPendingPointer()
            return
        }

        // Movement gate: if the new sample is within `pointerMovementThreshold`
        // points of the last committed value, drop it.
        if let new = point, let last = lastCommittedPointer {
            let dx = abs(new.x - last.x)
            let dy = abs(new.y - last.y)
            if dx < Self.pointerMovementThreshold && dy < Self.pointerMovementThreshold {
                return
            }
        }

        pendingPointer = point

        let now = CACurrentMediaTime()
        if now - lastPointerCommitTime >= Self.pointerCommitInterval {
            commitPendingPointer()
            return
        }

        // Already armed — let the existing timer flush the pending sample.
        guard pointerCoalesceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = Self.pointerCommitInterval - (now - lastPointerCommitTime)
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.commitPendingPointer()
        }
        pointerCoalesceTimer = timer
        timer.resume()
    }

    private func commitPendingPointer() {
        pointerCoalesceTimer?.cancel()
        pointerCoalesceTimer = nil
        let next = pendingPointer
        pendingPointer = nil
        lastCommittedPointer = next
        lastPointerCommitTime = CACurrentMediaTime()
        viewModel.pointer = next
    }

    private func scheduleDesktopClickCycleIfNeeded() {
        guard viewModel.allowsDesktopClickCycle else { return }
        let globalPoint = NSEvent.mouseLocation
        guard targetScreen.frame.contains(globalPoint) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.viewModel.allowsDesktopClickCycle,
                  self.targetScreen.frame.contains(globalPoint) else {
                return
            }
            NotificationCenter.default.post(name: .cycleSwarmShapeRequested, object: nil)
        }
    }

    private func convertScreenPointToLocal(_ globalPoint: NSPoint) -> CGPoint {
        let screenFrame = targetScreen.frame
        // Convert bottom-left y-up (macOS) to top-left y-down (SwiftUI Canvas)
        let localX = globalPoint.x - screenFrame.origin.x
        let localY = screenFrame.height - (globalPoint.y - screenFrame.origin.y)
        return CGPoint(x: localX, y: localY)
    }

    override public var canBecomeKey: Bool {
        return false
    }

    override public var canBecomeMain: Bool {
        return false
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        pointerCoalesceTimer?.cancel()
        pointerCoalesceTimer = nil
    }
}
