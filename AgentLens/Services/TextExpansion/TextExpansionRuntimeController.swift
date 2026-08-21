#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os
import OpenBurnBarCore

/// Drives global (system-wide) text expansion on macOS via a `CGEvent` session tap.
///
/// A session-level **active** tap (`.cgSessionEventTap` + `.defaultTap`) is the proven
/// mechanism for this: it is authorized by the **Accessibility** TCC grant (not Input
/// Monitoring), it can *swallow* the triggering keystroke so the literal `&&trigger`
/// never lands in the field, and it survives across apps. A passive `NSEvent` global
/// monitor cannot swallow events and is less reliable for keyboard capture, so we use a
/// tap and re-enable it whenever the system disables it.
@MainActor
final class TextExpansionRuntimeController: ObservableObject {
    private let dataStore: DataStoreCoordinator
    private let settingsManager: SettingsManager
    private let inputController: MacInputController
    private let accessibilityInspector: MacAccessibilityInspector
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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

    // State touched by the nonisolated CGEvent tap callback (off the main actor),
    // confined to an OSAllocatedUnfairLock so the controller stays Sendable.
    //
    // The callback runs synchronously on the main run loop for every keystroke, and macOS
    // disables a tap whose callback is slow. So the hot path must NOT call AX/NSWorkspace
    // APIs (they are cross-process and slow). Instead we cache the policy inputs here and
    // refresh them off the hot path (app-activation notifications + the poll timer).
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
        refreshTapRuntimeSnapshot()
        bootstrapCachedSnippetsFromSnapshot()
        reconcileEventTap()
        startPermissionPollTimerIfNeeded()
        Task { @MainActor [weak self] in
            await self?.refreshCachedSnippets()
        }
    }

    @MainActor
    func stop() {
        stopPermissionPollTimer()
        stopEventTap()
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
                self?.reconcileEventTap()
                self?.startPermissionPollTimerIfNeeded()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileEventTap()
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
                self?.refreshTapRuntimeSnapshot()
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

    /// Refresh the cached policy inputs the tap callback reads. Runs off the hot path
    /// (start, app activation, reconcile, poll timer) so the per-keystroke callback never
    /// touches AX or NSWorkspace.
    @MainActor
    private func refreshTapRuntimeSnapshot() {
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
                self?.reconcileEventTap()
            }
        }
    }

    @MainActor
    private func stopPermissionPollTimer() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Event tap

    @MainActor
    private func reconcileEventTap() {
        refreshTapRuntimeSnapshot()
        let enabled = settingsManager.textExpansion.macGlobalExpansionEnabled
        let trusted = inputController.isAccessibilityTrusted()
        let logKey = "enabled=\(enabled) trusted=\(trusted) tapExists=\(eventTap != nil)"
        if lastReconcileLogKey != logKey {
            AppLogger.chat.notice("textExpansion.reconcile \(logKey)")
            lastReconcileLogKey = logKey
        }
        guard enabled else {
            stopEventTap()
            return
        }
        guard trusted else {
            // Feature is on but we are not trusted (commonly: a dev rebuild changed the
            // binary's cdhash and macOS pinned the Accessibility grant to the old one).
            // Tear down any stale tap, guide the user once, and let the poll timer install
            // the tap automatically the instant trust is (re)granted — no relaunch needed.
            if eventTap != nil {
                AppLogger.chat.notice("textExpansion.tapTornDownUntrusted")
            }
            stopEventTap()
            needsAccessibilityGrant = true
            return
        }
        needsAccessibilityGrant = false
        didPromptForAccessibility = false
        startEventTapIfNeeded()
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
    private func startEventTapIfNeeded() {
        bootstrapCachedSnippetsFromSnapshot()
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) else {
            AppLogger.chat.error("textExpansion.tapCreateFailed", metadata: [
                "accessibilityTrusted": "\(inputController.isAccessibilityTrusted())"
            ])
            if !inputController.isAccessibilityTrusted() {
                // Same rule as `reconcileEventTap`: surface it, do not seize the
                // screen. `startEventTapIfNeeded` runs on the launch path.
                needsAccessibilityGrant = true
            }
            return
        }
        eventTap = tap
        callbackState.withLockUnchecked { $0.sawFirstEvent = false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.chat.notice("textExpansion.tapInstalled", metadata: [
            "snippetCount": "\(callbackState.withLockUnchecked { $0.cachedSnippets.count })"
        ])
    }

    @MainActor
    private func stopEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        callbackState.withLockUnchecked {
            $0.buffer = ""
            $0.sawFirstEvent = false
        }
    }

    /// The system disables a tap if its callback is too slow or after certain user input.
    /// When that happens it must be explicitly re-enabled or expansion silently dies.
    @MainActor
    private func reEnableTapAfterDisable(reason: String) {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        AppLogger.chat.notice("textExpansion.tapReenabled", metadata: ["reason": reason])
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

    // MARK: - Tap callback

    nonisolated private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<TextExpansionRuntimeController>.fromOpaque(refcon).takeUnretainedValue()
        return controller.handleEvent(type: type, event: event)
    }

    nonisolated private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            DispatchQueue.main.async { [weak self] in
                self?.reEnableTapAfterDisable(reason: reason)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // One-shot liveness beacon: proves the tap is actually receiving keystrokes under
        // the current permission grant. If this never fires after typing, the tap is dead.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isFirst = callbackState.withLockUnchecked { state -> Bool in
            if state.sawFirstEvent { return false }
            state.sawFirstEvent = true
            return true
        }
        if isFirst {
            AppLogger.chat.notice("textExpansion.firstKeyObserved", metadata: ["keyCode": "\(keyCode)"])
        }

        guard Date() >= lockedSuppressEventsUntil() else { return Unmanaged.passUnretained(event) }

        // Hot path: read only the cached policy snapshot. No AX / NSWorkspace calls here —
        // those are slow enough that macOS would disable the tap (causing lag + dropped keys).
        let policy = callbackState.withLockUnchecked {
            (own: $0.ownBundleIdentifier, frontmost: $0.frontmostBundleIdentifier,
             enabled: $0.globalEnabled, trusted: $0.accessibilityTrusted)
        }
        guard policy.enabled, policy.trusted else {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }
        if let own = policy.own, own == policy.frontmost {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 51 { // Delete/Backspace
            removeLastBufferCharacter()
            return Unmanaged.passUnretained(event)
        }

        guard let chars = TextExpansionKeyEventCharacters.characters(fromCGEvent: event), !chars.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        let match = appendAndMatch(chars, bundleIdentifier: policy.frontmost)
        guard let match, !match.requiresPreview else {
            return Unmanaged.passUnretained(event)
        }

        // Only on an actual trigger match (rare) do we pay for the AX secure-field check,
        // and we do it before swallowing the key — never expand into a secure/password field.
        let secureSurface = MainActor.assumeIsolated { isFocusedSecureSurface() }
        if secureSurface {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        // The tap swallows this triggering keystroke, so the field holds the trigger token
        // minus the just-typed character. Delete exactly what is on screen, then type the
        // body (re-adding the boundary character the user intended, e.g. the space).
        let boundary = match.boundary.map(String.init) ?? ""
        let deleteCount: Int
        if match.boundary == nil {
            deleteCount = max(0, match.token.count - chars.count)
        } else {
            deleteCount = match.token.count
        }
        setSuppressEvents(for: 1.5)
        AppLogger.chat.notice("textExpansion.match", metadata: [
            "trigger": match.snippet.trigger,
            "deleteCount": "\(deleteCount)",
            "hasBoundary": "\(match.boundary != nil)"
        ])
        DispatchQueue.main.async { [weak self] in
            self?.replaceTypedToken(deleteCount: deleteCount, replacement: match.snippet.body + boundary, trigger: match.snippet.trigger)
        }
        return nil
    }

    @MainActor
    private func replaceTypedToken(deleteCount: Int, replacement: String, trigger: String) {
        do {
            let method = try TextExpansionFocusedTextInserter.replaceTrailingText(
                deleteCount: deleteCount,
                replacement: replacement,
                inputController: inputController
            )
            AppLogger.chat.notice("textExpansion.replaced method=\(method)")
        } catch {
            AppLogger.chat.silentFailure("textExpansion.globalReplace", error: error, context: ["trigger": trigger])
        }
        callbackState.withLockUnchecked { $0.buffer = "" }
    }

    @MainActor
    private func isFocusedSecureSurface() -> Bool {
        accessibilityInspector.denyReason(for: accessibilityInspector.focusedSnapshot()) != nil
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
    /// - Returns: the method used (`"ax"` or `"synthetic"`) for diagnostics.
    @discardableResult
    static func replaceTrailingText(
        deleteCount: Int,
        replacement: String,
        inputController: MacInputController
    ) throws -> String {
        guard deleteCount > 0 else {
            if !replacement.isEmpty { _ = try inputController.type(text: replacement) }
            return "insert"
        }
        if replaceViaAccessibility(deleteCount: deleteCount, replacement: replacement) {
            return "ax"
        }
        try replaceViaSyntheticKeys(deleteCount: deleteCount, replacement: replacement, inputController: inputController)
        return "synthetic"
    }

    private static func replaceViaAccessibility(deleteCount: Int, replacement: String) -> Bool {
        guard let element = focusedElement(), isTextSurface(element) else { return false }
        guard let cursor = selectedLocation(in: element), cursor >= deleteCount else { return false }

        // Select exactly the trigger text we want to replace, then overwrite just that
        // selection. This is atomic and preserves the rest of the field's content and
        // formatting (unlike rewriting the whole AX value, which flattens rich text).
        var triggerRange = CFRange(location: cursor - deleteCount, length: deleteCount)
        guard let rangeValue = AXValueCreate(.cfRange, &triggerRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        ) == .success
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
