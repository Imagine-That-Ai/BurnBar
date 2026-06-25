#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os
import OpenBurnBarCore

@MainActor
final class TextExpansionRuntimeController: ObservableObject {
    private let dataStore: DataStoreCoordinator
    private let settingsManager: SettingsManager
    private let inputController: MacInputController
    private let accessibilityInspector: MacAccessibilityInspector
    private var globalKeyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var permissionPollTimer: Timer?

    private struct CallbackState {
        var buffer = ""
        var cachedSnippets: [TextExpansionSnippet] = []
        var lastSnippetLoad = Date.distantPast
        var snippetRefreshInFlight = false
        var suppressEventsUntil = Date.distantPast
        var runtime = TextExpansionGlobalTapPolicy()
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
    }

    @MainActor
    func start() {
        installObserversIfNeeded()
        refreshTapRuntimeSnapshot()
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
                self?.refreshTapRuntimeSnapshot()
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
                self?.refreshTapRuntimeSnapshot()
                self?.reconcileGlobalKeyMonitor()
            }
        })
        observers.append(center.addObserver(
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

    @MainActor
    private func startPermissionPollTimerIfNeeded() {
        guard settingsManager.textExpansion.macGlobalExpansionEnabled else {
            stopPermissionPollTimer()
            return
        }
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTapRuntimeSnapshot()
                self?.reconcileGlobalKeyMonitor()
            }
        }
    }

    @MainActor
    private func stopPermissionPollTimer() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    @MainActor
    private func refreshTapRuntimeSnapshot() {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focusedSurfaceDenied = accessibilityInspector.denyReason(
            for: accessibilityInspector.focusedSnapshot()
        ) != nil
        let runtime = TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: settingsManager.textExpansion.macGlobalExpansionEnabled,
            accessibilityTrusted: inputController.isAccessibilityTrusted(),
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            focusedSurfaceDenied: focusedSurfaceDenied
        )
        callbackState.withLockUnchecked { $0.runtime = runtime }
    }

    @MainActor
    private func reconcileGlobalKeyMonitor() {
        refreshTapRuntimeSnapshot()
        guard settingsManager.textExpansion.macGlobalExpansionEnabled,
              inputController.isAccessibilityTrusted() else {
            stopGlobalKeyMonitor()
            return
        }
        startGlobalKeyMonitorIfNeeded()
    }

    @MainActor
    private func startGlobalKeyMonitorIfNeeded() {
        bootstrapCachedSnippetsFromSnapshot()
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event)
        }
        if globalKeyMonitor == nil {
            AppLogger.chat.error(
                "textExpansion.globalKeyMonitorCreateFailed",
                metadata: ["accessibilityTrusted": "\(inputController.isAccessibilityTrusted())"]
            )
            if !inputController.isAccessibilityTrusted() {
                _ = MacAccessibilityPermissionRequester.promptAndOpenSettings()
            }
        }
    }

    @MainActor
    private func stopGlobalKeyMonitor() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        globalKeyMonitor = nil
        callbackState.withLockUnchecked { $0.buffer = "" }
    }

    @MainActor
    private func bootstrapCachedSnippetsFromSnapshot() {
        guard let url = TextExpansionSnapshotStore.snapshotURL(),
              let snapshot = try? TextExpansionSnapshotStore.read(from: url) else { // try?-ok(snapshot fallback)
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

    nonisolated private func handleGlobalKeyDown(_ event: NSEvent) {
        guard Date() >= lockedSuppressEventsUntil() else { return }

        let ownBundleIdentifier = callbackState.withLockUnchecked { $0.runtime.ownBundleIdentifier }
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if ownBundleIdentifier != nil, ownBundleIdentifier == frontmostBundleIdentifier {
            resetBuffer()
            return
        }

        let runtime = lockedRuntimeSnapshot()
        guard runtime.globalExpansionEnabled, runtime.accessibilityTrusted else {
            resetBuffer()
            return
        }

        if !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            resetBuffer()
            return
        }

        if event.keyCode == 51 {
            removeLastBufferCharacter()
            return
        }

        guard let chars = TextExpansionKeyEventCharacters.characters(from: event), !chars.isEmpty else {
            return
        }

        let match = appendAndMatch(chars, bundleIdentifier: frontmostBundleIdentifier)
        guard let match, !match.requiresPreview else { return }

        let plan = TextExpansionGlobalReplacementPlanner.plan(for: match)
        let expectedTrailingText = match.token + (match.boundary.map(String.init) ?? "")
        setSuppressEvents(for: 1.5)
        resetBuffer()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.canReplaceOnFocusedSurface() else { return }
            self.applyGlobalReplacement(
                deleteCount: plan.deleteCount,
                expectedTrailingText: expectedTrailingText,
                replacement: plan.replacement
            )
        }
    }

    @MainActor
    private func canReplaceOnFocusedSurface() -> Bool {
        accessibilityInspector.denyReason(for: accessibilityInspector.focusedSnapshot()) == nil
    }

    @MainActor
    private func applyGlobalReplacement(deleteCount: Int, expectedTrailingText: String, replacement: String) {
        do {
            try TextExpansionFocusedTextInserter.replaceTrailingText(
                deleteCount: deleteCount,
                expectedTrailingText: expectedTrailingText,
                replacement: replacement,
                inputController: inputController
            )
        } catch {
            AppLogger.chat.silentFailure("textExpansion.globalReplace", error: error)
        }
    }

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

    @MainActor
    private func refreshCachedSnippets() async {
        let fetched: [TextExpansionSnippet]
        do {
            fetched = try await dataStore.fetchEnabledTextExpansionSnippets(surface: .macGlobal)
        } catch {
            fetched = []
        }

        let resolved: [TextExpansionSnippet]
        if fetched.isEmpty {
            if let url = TextExpansionSnapshotStore.snapshotURL(),
               let snapshot = try? TextExpansionSnapshotStore.read(from: url) { // try?-ok(snapshot fallback)
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

    nonisolated private func lockedRuntimeSnapshot() -> TextExpansionGlobalTapPolicy {
        callbackState.withLockUnchecked { $0.runtime }
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

private enum TextExpansionFocusedTextInserter {
    enum InsertError: Error {
        case accessibilityNotTrusted
        case valueMutationUnsupported
    }

    private enum AccessibilityReplacementResult {
        case replaced
        case unsupported
        case staleFocusedText
    }

    static func replaceTrailingText(
        deleteCount: Int,
        expectedTrailingText: String,
        replacement: String,
        inputController: MacInputController
    ) throws {
        guard deleteCount > 0 else { return }
        guard inputController.isAccessibilityTrusted() else {
            throw InsertError.accessibilityNotTrusted
        }

        switch try replaceViaAccessibility(
            deleteCount: deleteCount,
            expectedTrailingText: expectedTrailingText,
            replacement: replacement
        ) {
        case .replaced:
            return
        case .staleFocusedText:
            return
        case .unsupported:
            try replaceViaSyntheticKeys(deleteCount: deleteCount, replacement: replacement, inputController: inputController)
        }
    }

    private static func replaceViaAccessibility(
        deleteCount: Int,
        expectedTrailingText: String,
        replacement: String
    ) throws -> AccessibilityReplacementResult {
        guard let element = focusedElement() else { return .unsupported }
        guard isTextSurface(element) else { return .unsupported }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return .unsupported
        }

        let selectedCursor = selectedLocation(in: element) ?? currentValue.utf16.count
        let cursor = min(max(selectedCursor, 0), currentValue.utf16.count)
        guard cursor >= deleteCount else { return .staleFocusedText }

        let deleteRange = NSRange(location: cursor - deleteCount, length: deleteCount)
        guard let range = Range(deleteRange, in: currentValue) else { return .staleFocusedText }
        guard currentValue[range] == expectedTrailingText else { return .staleFocusedText }
        var updated = currentValue
        updated.replaceSubrange(range, with: replacement)

        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFTypeRef)
        guard setResult == .success else {
            return .unsupported
        }
        return .replaced
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
        ) == .success else {
            return nil
        }
        guard let focusedRef else { return nil }
        return focusedRef as? AXUIElement
    }

    private static func isTextSurface(_ element: AXUIElement) -> Bool {
        let role = attributeString(element, kAXRoleAttribute as CFString)?.lowercased() ?? ""
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
        ) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    private static func attributeString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }
}
#endif
