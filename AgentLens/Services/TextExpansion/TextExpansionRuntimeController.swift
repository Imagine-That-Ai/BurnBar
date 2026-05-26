#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import CoreGraphics
import Foundation
import OpenBurnBarCore

final class TextExpansionRuntimeController: ObservableObject, @unchecked Sendable {
    private let dataStore: DataStoreCoordinator
    private let settingsManager: SettingsManager
    private let inputController: MacInputController
    private let accessibilityInspector: MacAccessibilityInspector
    private let lock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private var cachedSnippets: [TextExpansionSnippet] = []
    private var lastSnippetLoad = Date.distantPast
    private var suppressEventsUntil = Date.distantPast

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
    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        buffer = ""
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
        if nsEvent.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
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
        setSuppressEvents(for: 1.5)
        DispatchQueue.main.async { [weak self] in
            self?.replaceTypedToken(token: match.token, replacement: match.snippet.body + boundary)
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
        lock.lock()
        buffer = ""
        lock.unlock()
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

    private func appendAndMatch(_ characters: String, bundleIdentifier: String?) -> TextExpansionMatch? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: characters)
        if buffer.count > 160 {
            buffer = String(buffer.suffix(160))
        }
        let snippets = cachedSnippetsLocked()
        return TextExpansionMatcher.match(
            in: buffer,
            snippets: snippets,
            surface: .macGlobal,
            bundleIdentifier: bundleIdentifier,
            expandWhenUnambiguous: false
        )
    }

    private func cachedSnippetsLocked() -> [TextExpansionSnippet] {
        let now = Date()
        guard now.timeIntervalSince(lastSnippetLoad) > 2 else { return cachedSnippets }
        lastSnippetLoad = now
        do {
            cachedSnippets = try dataStore.fetchEnabledTextExpansionSnippets(surface: .macGlobal)
        } catch {
            cachedSnippets = []
        }
        return cachedSnippets
    }

    private func resetBuffer() {
        lock.lock()
        buffer = ""
        lock.unlock()
    }

    private func removeLastBufferCharacter() {
        lock.lock()
        if !buffer.isEmpty {
            buffer.removeLast()
        }
        lock.unlock()
    }

    private func setSuppressEvents(for interval: TimeInterval) {
        lock.lock()
        suppressEventsUntil = Date().addingTimeInterval(interval)
        lock.unlock()
    }

    private func lockedSuppressEventsUntil() -> Date {
        lock.lock()
        let value = suppressEventsUntil
        lock.unlock()
        return value
    }
}
#endif
