#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
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
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    // State touched by the nonisolated CGEvent tap callback (off the main actor),
    // confined to an OSAllocatedUnfairLock so the controller stays Sendable.
    private struct CallbackState {
        var buffer = ""
        var cachedSnippets: [TextExpansionSnippet] = []
        var lastSnippetLoad = Date.distantPast
        var suppressEventsUntil = Date.distantPast
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
        reconcileEventTap()
    }

    @MainActor
    func stop() {
        stopEventTap()
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
                self?.reconcileEventTap()
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
    }

    @MainActor
    private func reconcileEventTap() {
        guard settingsManager.textExpansion.macGlobalExpansionEnabled,
              inputController.isAccessibilityTrusted() else {
            stopEventTap()
            return
        }
        startEventTapIfNeeded()
    }

    @MainActor
    private func startEventTapIfNeeded() {
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
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        callbackState.withLockUnchecked { $0.buffer = "" }
    }

    nonisolated private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<TextExpansionRuntimeController>.fromOpaque(refcon).takeUnretainedValue()
        return controller.handleEvent(type: type, event: event)
    }

    nonisolated private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard Date() >= lockedSuppressEventsUntil() else { return Unmanaged.passUnretained(event) }

        let frontmostBundleIdentifier = MainActor.assumeIsolated {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let shouldProcess = MainActor.assumeIsolated {
            settingsManager.textExpansion.macGlobalExpansionEnabled
                && inputController.isAccessibilityTrusted()
                && !isFrontmostOpenBurnBar(frontmostBundleIdentifier: frontmostBundleIdentifier)
                && !isFocusedSecureSurface()
        }
        guard shouldProcess else {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        if !nsEvent.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == 51 {
            removeLastBufferCharacter()
            return Unmanaged.passUnretained(event)
        }

        guard let chars = nsEvent.charactersIgnoringModifiers, !chars.isEmpty else {
            resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        let match = appendAndMatch(chars, bundleIdentifier: frontmostBundleIdentifier)
        guard let match, !match.requiresPreview else {
            return Unmanaged.passUnretained(event)
        }

        let boundary = match.boundary.map(String.init) ?? ""
        let typedToken: String
        if match.boundary == nil {
            typedToken = String(match.token.dropLast(chars.count))
        } else {
            typedToken = match.token
        }
        setSuppressEvents(for: 1.5)
        DispatchQueue.main.async { [weak self] in
            self?.replaceTypedToken(token: typedToken, replacement: match.snippet.body + boundary)
        }
        return nil
    }

    @MainActor
    private func replaceTypedToken(token: String, replacement: String) {
        do {
            for _ in token {
                try inputController.key("Delete")
            }
            _ = try inputController.type(text: replacement)
        } catch {
            AppLogger.chat.silentFailure("textExpansion.globalReplace", error: error)
        }
        callbackState.withLockUnchecked { $0.buffer = "" }
    }

    @MainActor
    private func isFrontmostOpenBurnBar(frontmostBundleIdentifier: String?) -> Bool {
        let own = Bundle.main.bundleIdentifier
        return own != nil && own == frontmostBundleIdentifier
    }

    @MainActor
    private func isFocusedSecureSurface() -> Bool {
        accessibilityInspector.denyReason(for: accessibilityInspector.focusedSnapshot()) != nil
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
        do {
            state.cachedSnippets = try dataStore.fetchEnabledTextExpansionSnippets(surface: .macGlobal)
        } catch {
            state.cachedSnippets = []
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
#endif
