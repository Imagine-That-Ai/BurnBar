#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import Combine
import Foundation
import OpenBurnBarCore

struct AgentFocusFollowTarget: Sendable, Equatable {
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String?
    var windowID: CGWindowID?

    var focusContext: HermesRealtimeRelayFocusContext {
        HermesRealtimeRelayFocusContext(
            appName: appName,
            bundleId: bundleIdentifier,
            windowTitle: windowTitle,
            windowId: windowID.map { UInt32($0) }
        )
    }
}

protocol AgentFocusFollowClock: Sendable {
    func sleep(for seconds: TimeInterval) async
}

struct SystemAgentFocusFollowClock: AgentFocusFollowClock {
    func sleep(for seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
final class AgentFocusFollowController {
    typealias TargetResolver = @MainActor @Sendable () async -> AgentFocusFollowTarget?
    typealias TargetSwitcher = @MainActor @Sendable (_ displayId: String?, _ windowID: CGWindowID?) async throws -> Void
    typealias FocusContextSink = @MainActor @Sendable (_ context: HermesRealtimeRelayFocusContext) async -> Void

    private let targetResolver: TargetResolver
    private let targetSwitcher: TargetSwitcher
    private let focusContextSink: FocusContextSink
    private let clock: any AgentFocusFollowClock
    private let notificationCenter: NotificationCenter

    private var observer: NSObjectProtocol?
    private var activeSessionId: String?
    private var pendingSwitchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var mode: AgentFocusFollowMode
    private var currentWindowID: CGWindowID?
    private var currentBundleIdentifier: String?
    private var currentFocusContext: HermesRealtimeRelayFocusContext?

    init(
        mode: AgentFocusFollowMode = .smart,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        clock: any AgentFocusFollowClock = SystemAgentFocusFollowClock(),
        targetResolver: @escaping TargetResolver = { await AgentFocusFollowController.resolveFrontmostTarget() },
        targetSwitcher: @escaping TargetSwitcher,
        focusContextSink: @escaping FocusContextSink
    ) {
        self.mode = mode
        self.notificationCenter = notificationCenter
        self.clock = clock
        self.targetResolver = targetResolver
        self.targetSwitcher = targetSwitcher
        self.focusContextSink = focusContextSink
    }

    func start(sessionId: String, mode: AgentFocusFollowMode? = nil) {
        activeSessionId = sessionId
        if let mode {
            self.mode = mode
        }
        installObserverIfNeeded()
        startHeartbeat()
        Task { @MainActor [weak self] in
            await self?.handleWorkspaceActivation()
        }
    }

    func stop() {
        activeSessionId = nil
        pendingSwitchTask?.cancel()
        pendingSwitchTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        currentWindowID = nil
        currentBundleIdentifier = nil
        currentFocusContext = nil
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    func setMode(_ mode: AgentFocusFollowMode) {
        self.mode = mode
        pendingSwitchTask?.cancel()
        pendingSwitchTask = nil
        Task { @MainActor [weak self] in
            await self?.handleWorkspaceActivation()
        }
    }

    func recordActivationForTesting(_ target: AgentFocusFollowTarget) {
        handleActivation(target)
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleWorkspaceActivation()
            }
        }
    }

    private func handleWorkspaceActivation() async {
        guard let target = await targetResolver() else { return }
        handleActivation(target)
    }

    private func handleActivation(_ target: AgentFocusFollowTarget) {
        guard activeSessionId != nil else { return }
        switch mode {
        case .immediate:
            Task { @MainActor [weak self] in
                await self?.switchNow(to: target)
            }
        case .debounced:
            scheduleSwitch(to: target, after: 0.5)
        case .smart:
            if currentBundleIdentifier == nil || target.bundleIdentifier == currentBundleIdentifier {
                scheduleSwitch(to: target, after: 0)
            } else {
                scheduleSwitch(to: target, after: 2.0)
            }
        }
    }

    private func scheduleSwitch(to target: AgentFocusFollowTarget, after delay: TimeInterval) {
        pendingSwitchTask?.cancel()
        pendingSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                await clock.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self.switchNow(to: target)
        }
    }

    private func switchNow(to target: AgentFocusFollowTarget) async {
        guard activeSessionId != nil else { return }
        let context = target.focusContext
        currentFocusContext = context
        currentBundleIdentifier = target.bundleIdentifier
        guard target.windowID != currentWindowID else {
            await focusContextSink(context)
            return
        }
        do {
            try await targetSwitcher(nil, target.windowID)
            currentWindowID = target.windowID
            await focusContextSink(context)
        } catch {
            try? await targetSwitcher(nil, nil)
            currentWindowID = nil
            await focusContextSink(context)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.clock.sleep(for: 1.0)
                guard !Task.isCancelled, let context = self.currentFocusContext else { continue }
                await self.focusContextSink(context)
            }
        }
    }

    private static func resolveFrontmostTarget() async -> AgentFocusFollowTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let appName = application.localizedName ?? application.bundleURL?.lastPathComponent ?? "Active App"
        let focusedTitle = frontmostWindowTitle(for: application.processIdentifier)
        let windows = await ScreenCapturePipeline.availableWindows()
        let sameAppWindows = windows.filter { $0.bundleIdentifier == bundleIdentifier }
        let matched = focusedTitle.flatMap { title in
            sameAppWindows.first { $0.title == title }
        } ?? sameAppWindows.first
        return AgentFocusFollowTarget(
            appName: matched?.appName ?? appName,
            bundleIdentifier: matched?.bundleIdentifier ?? bundleIdentifier,
            windowTitle: matched?.title ?? focusedTitle,
            windowID: matched?.windowID
        )
    }

    private static func frontmostWindowTitle(for processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focused: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)
        guard focusedErr == .success, let window = focused else { return nil }
        var title: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard titleErr == .success else { return nil }
        return (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyForFocusFollow
    }
}

private extension String {
    var nilIfEmptyForFocusFollow: String? {
        isEmpty ? nil : self
    }
}
#endif
