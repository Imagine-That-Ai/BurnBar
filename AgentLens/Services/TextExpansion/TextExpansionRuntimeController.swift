#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import Foundation
import os
import OpenBurnBarCore

/// Drives global (system-wide) text expansion on macOS through a passive key monitor.
///
/// The monitor observes key-down events after the focused app receives them. When a
/// complete static trigger is present, the original token is replaced asynchronously
/// through Accessibility. This deliberately never swallows or rewrites the original
/// event, which keeps Safari's own extension-permission controls in charge of clicks.
@MainActor
final class TextExpansionRuntimeController: ObservableObject {
    private let dataStore: DataStoreCoordinator
    private let settingsManager: SettingsManager
    private let inputController: MacInputController
    private let accessibilityInspector: MacAccessibilityInspector
    private var globalKeyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var permissionPollTimer: Timer?
    private var lastReconcileLogKey: String?
    private var didPromptForAccessibility = false

    /// True when text expansion is switched on but macOS has not granted (or has
    /// forgotten) Accessibility trust -- typically after an app update re-signs the
    /// binary and the grant stays pinned to the old cdhash.
    ///
    /// Settings renders this as an inline row. It deliberately does NOT prompt on
    /// its own: at launch the user has not asked for anything, and seizing the
    /// screen with a permission dialog plus a System Settings window is exactly
    /// the behaviour that makes a freshly-updated app feel like malware.
    @Published private(set) var needsAccessibilityGrant = false

    // State touched by the nonisolated global-monitor callback (off the main actor),
    // confined to an OSAllocatedUnfairLock so the controller stays Sendable. The hot path
    // must not call AX/NSWorkspace APIs (they are cross-process and slow), so policy inputs
    // are cached and refreshed on app activation and the permission poll.
    private struct CallbackState {
        var buffer = ""
        var cachedSnippets: [TextExpansionSnippet] = []
        var lastSnippetLoad = Date.distantPast
        var snippetRefreshInFlight = false
        var suppressEventsUntil = Date.distantPast
        var ownBundleIdentifier: String?
        var frontmostBundleIdentifier: String?
        var globalEnabled = false
        var accessibilityTrusted = false
        var sawFirstEvent = false
    }
    private let callbackState = OSAllocatedUnfairLock<CallbackState>(uncheckedState: CallbackState())

    init(
        dataStore: DataStoreCoordinator,
        settingsManager: SettingsManager,
        inputController: MacInputController = MacInputController(),
        accessibilityInspector: MacAccessibilityInspector = MacAccessibilityInspector()
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.inputController = inputController
        self.accessibilityInspector = accessibilityInspector
        let ownBundle = Bundle.main.bundleIdentifier
        callbackState.withLockUnchecked { $0.ownBundleIdentifier = ownBundle }
    }

    // MARK: - Lifecycle

    @MainActor
    func start() {
        AppLogger.chat.notice("textExpansion.start", metadata: [
            "globalEnabled": "\(settingsManager.textExpansion.macGlobalExpansionEnabled)",
            "accessibilityTrusted": "\(inputController.isAccessibilityTrusted())"
        ])
        installObserversIfNeeded()
        refreshGlobalMonitorRuntimeSnapshot()
        bootstrapCachedSnippetsFromSnapshot()
        reconcileGlobalKeyMonitor()
        startPermissionPollTimerIfNeeded()
        Task { @MainActor [weak self] in
            await self?.refreshCachedSnippets()
        }
    }

    @MainActor
    func stop() {
        stopPermissionPollTimer()
        stopGlobalKeyMonitor()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    @MainActor
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .textExpansionMacGlobalExpansionEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileGlobalKeyMonitor()
                self?.startPermissionPollTimerIfNeeded()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileGlobalKeyMonitor()
            }
        })
        // Cache the frontmost app off the hot path: the tap callback must not call
        // NSWorkspace per keystroke. App switches are the only time this changes.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshGlobalMonitorRuntimeSnapshot()
            }
        })
        observers.append(center.addObserver(
            forName: .textExpansionSnippetsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshCachedSnippets()
            }
        })
    }

    /// Refresh the cached policy inputs the global monitor reads. Runs off the hot path
    /// (start, app activation, reconcile, poll timer) so the per-keystroke callback never
    /// touches AX or NSWorkspace.
    @MainActor
    private func refreshGlobalMonitorRuntimeSnapshot() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let enabled = settingsManager.textExpansion.macGlobalExpansionEnabled
        let trusted = inputController.isAccessibilityTrusted()
        callbackState.withLockUnchecked { state in
            state.frontmostBundleIdentifier = frontmost
            state.globalEnabled = enabled
            state.accessibilityTrusted = trusted
        }
    }

    // MARK: - Permission polling

    /// Accessibility trust is granted asynchronously (the user flips a switch in System
    /// Settings while the app is already running) and dev rebuilds can silently invalidate
    /// it. Poll so the tap installs/heals without requiring an app relaunch.
    @MainActor
    private func startPermissionPollTimerIfNeeded() {
        guard settingsManager.textExpansion.macGlobalExpansionEnabled else {
            stopPermissionPollTimer()
            return
        }
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileGlobalKeyMonitor()
            }
        }
    }

    @MainActor
    private func stopPermissionPollTimer() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Global key monitor

    @MainActor
    private func reconcileGlobalKeyMonitor() {
        refreshGlobalMonitorRuntimeSnapshot()
        let enabled = settingsManager.textExpansion.macGlobalExpansionEnabled
        let trusted = inputController.isAccessibilityTrusted()
        let logKey = "enabled=\(enabled) trusted=\(trusted) monitorExists=\(globalKeyMonitor != nil)"
        if lastReconcileLogKey != logKey {
            AppLogger.chat.notice("textExpansion.reconcile \(logKey)")
            lastReconcileLogKey = logKey
        }
        guard enabled else {
            stopGlobalKeyMonitor()
            return
        }
        guard trusted else {
            // Feature is on but we are not trusted (commonly: a dev rebuild changed the
            // binary's cdhash and macOS pinned the Accessibility grant to the old one).
            // Tear down any stale monitor, guide the user once, and let the poll timer
            // install the monitor automatically the instant trust is (re)granted.
            if globalKeyMonitor != nil {
                AppLogger.chat.notice("textExpansion.monitorTornDownUntrusted")
            }
            stopGlobalKeyMonitor()
            needsAccessibilityGrant = true
            return
        }
        needsAccessibilityGrant = false
        didPromptForAccessibility = false
        startGlobalKeyMonitorIfNeeded()
    }

    /// Shows the macOS Accessibility prompt and opens System Settings.
    ///
    /// Call this only from a control the user just clicked. The launch path
    /// publishes `needsAccessibilityGrant` instead, so the ask happens when the
    /// user goes looking for it rather than the instant the app opens.
    @MainActor
    func requestAccessibilityGrantFromUser() {
        guard !didPromptForAccessibility else { return }
        didPromptForAccessibility = true
        AppLogger.chat.notice("textExpansion.promptAccessibility")
        _ = MacAccessibilityPermissionRequester.promptAndOpenSettings()
    }

    @MainActor
    private func startGlobalKeyMonitorIfNeeded() {
        bootstrapCachedSnippetsFromSnapshot()
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event)
        }
        guard globalKeyMonitor != nil else {
            AppLogger.chat.error("textExpansion.globalKeyMonitorCreateFailed", metadata: [
                "accessibilityTrusted": "\(inputController.isAccessibilityTrusted())"
            ])
            return
        }
        callbackState.withLockUnchecked {
            $0.sawFirstEvent = false
        }
        AppLogger.chat.notice("textExpansion.globalKeyMonitorInstalled", metadata: [
            "snippetCount": "\(callbackState.withLockUnchecked { $0.cachedSnippets.count })"
        ])
    }

    @MainActor
    private func stopGlobalKeyMonitor() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        globalKeyMonitor = nil
        callbackState.withLockUnchecked {
            $0.buffer = ""
            $0.sawFirstEvent = false
        }
    }

    // MARK: - Snippet cache

    @MainActor
    private func bootstrapCachedSnippetsFromSnapshot() {
        guard let url = TextExpansionSnapshotStore.snapshotURL(),
              let snapshot = try? TextExpansionSnapshotStore.read(from: url) else { // try?-ok(absent/corrupt snapshot is expected; skip bootstrap)
            return
        }
        let snippets = snapshot.snippets
            .filter(\.isEnabled)
            .filter { $0.deletedAt == nil }
            .filter { $0.scope.allows(surface: .macGlobal) }
        callbackState.withLockUnchecked { state in
            guard state.cachedSnippets.isEmpty else { return }
            state.cachedSnippets = snippets
            state.lastSnippetLoad = Date()
        }
    }

    @MainActor
    private func refreshCachedSnippets() async {
        let fetched: [TextExpansionSnippet]
        do {
            fetched = try await dataStore.fetchEnabledTextExpansionSnippets(surface: .macGlobal)
        } catch {
            fetched = []
        }

        // Fall back to the on-disk snapshot when the DB fetch is empty/failed so a transient
        // store error never wipes a working snippet set out from under the tap.
        let resolved: [TextExpansionSnippet]
        if fetched.isEmpty {
            if let url = TextExpansionSnapshotStore.snapshotURL(),
               let snapshot = try? TextExpansionSnapshotStore.read(from: url) { // try?-ok(absent/corrupt snapshot is expected; fall back to cache)
                resolved = snapshot.snippets
                    .filter(\.isEnabled)
                    .filter { $0.deletedAt == nil }
                    .filter { $0.scope.allows(surface: .macGlobal) }
            } else {
                resolved = callbackState.withLockUnchecked { $0.cachedSnippets }
            }
        } else {
            resolved = fetched
        }

        callbackState.withLockUnchecked { state in
            if !resolved.isEmpty {
                state.cachedSnippets = resolved
                state.lastSnippetLoad = Date()
            }
            state.snippetRefreshInFlight = false
        }
    }

    // MARK: - Global monitor callback

    nonisolated private func handleGlobalKeyDown(_ event: NSEvent) {
        // One-shot liveness beacon: proves the monitor is receiving keystrokes under the
        // current permission grant.
        let keyCode = event.keyCode
        let isFirst = callbackState.withLockUnchecked { state -> Bool in
            if state.sawFirstEvent { return false }
            state.sawFirstEvent = true
            return true
        }
        if isFirst {
            AppLogger.chat.notice("textExpansion.firstKeyObserved", metadata: ["keyCode": "\(keyCode)"])
        }

        guard Date() >= lockedSuppressEventsUntil() else { return }

        // Hot path: read only the cached policy snapshot. No AX / NSWorkspace calls here.
        let policy = callbackState.withLockUnchecked {
            (own: $0.ownBundleIdentifier, frontmost: $0.frontmostBundleIdentifier,
             enabled: $0.globalEnabled, trusted: $0.accessibilityTrusted)
        }
        guard policy.enabled, policy.trusted else {
            resetBuffer()
            return
        }
        if let own = policy.own, own == policy.frontmost {
            resetBuffer()
            return
        }

        if !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            resetBuffer()
            return
        }

        if keyCode == 51 { // Delete/Backspace
            removeLastBufferCharacter()
            return
        }

        guard let chars = TextExpansionKeyEventCharacters.characters(from: event), !chars.isEmpty else {
            resetBuffer()
            return
        }

        guard let frontmostBundleIdentifier = policy.frontmost else {
            resetBuffer()
            return
        }
        let match = appendAndMatch(chars, bundleIdentifier: frontmostBundleIdentifier)
        guard let match, !match.requiresPreview else {
            return
        }

        // The passive monitor sees the key after the app has received it, so the
        // replacement plan includes the boundary character when one triggered the match.
        let plan = TextExpansionGlobalReplacementPlanner.plan(for: match)
        let expectedTrailingText = match.token + (match.boundary.map(String.init) ?? "")
        setSuppressEvents(for: 1.5)
        resetBuffer()
        AppLogger.chat.notice("textExpansion.match", metadata: [
            "trigger": match.snippet.trigger,
            "deleteCount": "\(plan.deleteCount)",
            "hasBoundary": "\(match.boundary != nil)"
        ])
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.canReplaceOnFocusedSurface(expectedBundleIdentifier: frontmostBundleIdentifier) else {
                return
            }
            self.applyGlobalReplacement(
                deleteCount: plan.deleteCount,
                expectedTrailingText: expectedTrailingText,
                replacement: plan.replacement
            )
        }
    }

    @MainActor
    private func canReplaceOnFocusedSurface(expectedBundleIdentifier: String) -> Bool {
        guard let snapshot = accessibilityInspector.focusedSnapshot(),
              snapshot.bundleId?.caseInsensitiveCompare(expectedBundleIdentifier) == .orderedSame else {
            return false
        }
        return accessibilityInspector.denyReason(for: snapshot) == nil
    }

    @MainActor
    private func applyGlobalReplacement(
        deleteCount: Int,
        expectedTrailingText: String,
        replacement: String
    ) {
        do {
            let method = try TextExpansionFocusedTextInserter.replaceTrailingText(
                deleteCount: deleteCount,
                expectedTrailingText: expectedTrailingText,
                replacement: replacement,
                inputController: inputController
            )
            AppLogger.chat.notice("textExpansion.replaced method=\(method)")
        } catch {
            AppLogger.chat.silentFailure("textExpansion.globalReplace", error: error)
        }
    }

    // MARK: - Buffer + matching (nonisolated, lock-protected)

    nonisolated private func appendAndMatch(_ characters: String, bundleIdentifier: String?) -> TextExpansionMatch? {
        callbackState.withLockUnchecked { state in
            state.buffer.append(contentsOf: characters)
            if state.buffer.count > 160 {
                state.buffer = String(state.buffer.suffix(160))
            }
            let snippets = cachedSnippets(into: &state)
            return TextExpansionMatcher.match(
                in: state.buffer,
                snippets: snippets,
                surface: .macGlobal,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    nonisolated private func cachedSnippets(into state: inout CallbackState) -> [TextExpansionSnippet] {
        let now = Date()
        guard now.timeIntervalSince(state.lastSnippetLoad) > 2 else { return state.cachedSnippets }
        state.lastSnippetLoad = now
        if !state.snippetRefreshInFlight {
            state.snippetRefreshInFlight = true
            Task { @MainActor [weak self] in
                await self?.refreshCachedSnippets()
            }
        }
        return state.cachedSnippets
    }

    nonisolated private func resetBuffer() {
        callbackState.withLockUnchecked { $0.buffer = "" }
    }

    nonisolated private func removeLastBufferCharacter() {
        callbackState.withLockUnchecked { state in
            if !state.buffer.isEmpty {
                state.buffer.removeLast()
            }
        }
    }

    nonisolated private func setSuppressEvents(for interval: TimeInterval) {
        callbackState.withLockUnchecked { $0.suppressEventsUntil = Date().addingTimeInterval(interval) }
    }

    nonisolated private func lockedSuppressEventsUntil() -> Date {
        callbackState.withLockUnchecked { $0.suppressEventsUntil }
    }
}

/// Inserts the expansion into the focused field.
///
/// Prefers an atomic Accessibility value mutation (instant, even for long snippet bodies —
/// synthesizing one keystroke per character is unbearably slow for multi-paragraph snippets).
/// Falls back to synthetic Delete+type for surfaces that do not expose a mutable AX value.
private enum TextExpansionFocusedTextInserter {
    private enum InsertError: Error {
        case accessibilityNotTrusted
    }

    private enum AccessibilityReplacementResult {
        case replaced
        case unsupported(target: AXUIElement?, validatedCurrentText: Bool)
        case staleFocusedText
    }

    /// - Returns: the method used (`"ax"` or `"synthetic"`) for diagnostics.
    @discardableResult
    static func replaceTrailingText(
        deleteCount: Int,
        expectedTrailingText: String,
        replacement: String,
        inputController: MacInputController
    ) throws -> String {
        guard deleteCount > 0 else {
            if !replacement.isEmpty { _ = try inputController.type(text: replacement) }
            return "insert"
        }

        guard inputController.isAccessibilityTrusted() else {
            throw InsertError.accessibilityNotTrusted
        }

        switch replaceViaAccessibility(
            deleteCount: deleteCount,
            expectedTrailingText: expectedTrailingText,
            replacement: replacement
        ) {
        case .replaced:
            return "ax"
        case .staleFocusedText:
            return "stale"
        case .unsupported(let target, let validatedCurrentText):
            // A passive monitor introduces a scheduling gap between the trigger
            // event and replacement. If AX could not perform an atomic replace,
            // only retain the synthetic fallback after the current field's text
            // was read and matched, and while that same focused element remains
            // active. Never blindly delete from a newly focused or unreadable field.
            guard validatedCurrentText,
                  let target,
                  isStillFocused(target) else { return "stale" }
            try replaceViaSyntheticKeys(deleteCount: deleteCount, replacement: replacement, inputController: inputController)
            return "synthetic"
        }
    }

    private static func replaceViaAccessibility(
        deleteCount: Int,
        expectedTrailingText: String,
        replacement: String
    ) -> AccessibilityReplacementResult {
        guard let element = focusedElement() else {
            return .unsupported(target: nil, validatedCurrentText: false)
        }
        guard isTextSurface(element) else {
            return .unsupported(target: element, validatedCurrentText: false)
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let currentValue = valueRef as? String else {
            return .unsupported(target: element, validatedCurrentText: false)
        }

        let selectedCursor = selectedLocation(in: element) ?? currentValue.utf16.count
        let cursor = min(max(selectedCursor, 0), currentValue.utf16.count)
        guard cursor >= deleteCount else { return .staleFocusedText }
        let deleteRange = NSRange(location: cursor - deleteCount, length: deleteCount)
        guard let range = Range(deleteRange, in: currentValue),
              currentValue[range] == expectedTrailingText else {
            return .staleFocusedText
        }

        // Select exactly the trigger text we want to replace, then overwrite just that
        // selection. This is atomic and preserves the rest of the field's content and
        // formatting (unlike rewriting the whole AX value, which flattens rich text).
        var triggerRange = CFRange(location: cursor - deleteCount, length: deleteCount)
        guard let rangeValue = AXValueCreate(.cfRange, &triggerRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            return .unsupported(target: element, validatedCurrentText: true)
        }
        let didReplace = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        ) == .success
        return didReplace
            ? .replaced
            : .unsupported(target: element, validatedCurrentText: true)
    }

    private static func isStillFocused(_ expected: AXUIElement) -> Bool {
        guard let current = focusedElement() else { return false }
        return CFEqual(expected, current)
    }

    private static func replaceViaSyntheticKeys(
        deleteCount: Int,
        replacement: String,
        inputController: MacInputController
    ) throws {
        for _ in 0..<deleteCount {
            try inputController.key("Delete")
        }
        _ = try inputController.type(text: replacement)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private static func isTextSurface(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success,
              let role = (raw as? String)?.lowercased() else {
            return false
        }
        return role == "axtextfield"
            || role == "axtextarea"
            || role == "axcombobox"
            || role == "axsearchfield"
    }

    private static func selectedLocation(in element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }
}
#endif
