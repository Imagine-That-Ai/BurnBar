import AppKit
import Carbon.HIToolbox

// MARK: - PetHotkey

/// A single rebindable global hotkey that summons/dismisses the pet bubble and
/// focuses its input (PLAN C8, default `⌥Space`).
///
/// Uses Carbon's `RegisterEventHotKey` — the only API that delivers a *system-
/// wide* hotkey to an `LSUIElement` accessory app without Accessibility/Input-
/// Monitoring entitlements (a global `NSEvent` monitor would require those and is
/// exactly what PLAN's "minimum needed" hardening avoids). The binding persists
/// to `UserDefaults` so it restores across launches, and `rebind(to:)` swaps it
/// live.
///
/// `@MainActor`: it mutates AppKit/Carbon UI registration, which is main-thread
/// only. A small singleton like the app's other shell coordinators.
@MainActor
final class PetHotkey {
    static let shared = PetHotkey()

    /// A persisted key combo: a Carbon virtual keycode + Carbon modifier mask.
    struct Combo: Equatable, Codable, Sendable {
        var keyCode: UInt32
        /// Carbon modifier flags (`optionKey`, `cmdKey`, …), OR-combined.
        var carbonModifiers: UInt32

        /// The default: `⌥Space`.
        static let defaultCombo = Combo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))

        /// Human-facing glyphs for the onboarding/settings label, e.g. `⌥Space`.
        var displayString: String {
            var s = ""
            if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            s += Self.keyName(keyCode)
            return s
        }

        private static func keyName(_ code: UInt32) -> String {
            switch Int(code) {
            case kVK_Space: return "Space"
            case kVK_Return: return "Return"
            case kVK_Escape: return "Esc"
            case kVK_ANSI_P: return "P"
            case kVK_ANSI_B: return "B"
            default: return "Key\(code)"
            }
        }
    }

    /// The action fired when the hotkey is pressed. Defaults to toggling the
    /// bubble on the shared controller; the host can override (e.g. to also
    /// summon the pet if hidden).
    var onTrigger: () -> Void = {
        PetCompanionController.shared.handlePetClick()
    }

    private static let defaultsKey = "pet.hotkey.combo"
    private let hotKeyID = EventHotKeyID(signature: OSType(0x42425052 /* "BBPR" */), id: 1)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var combo: Combo

    private init() {
        combo = Self.loadCombo() ?? .defaultCombo
    }

    // MARK: Registration

    /// Install the global handler and register the current combo. Idempotent —
    /// safe to call from the launch hook. Returns `false` if registration failed
    /// (e.g. the combo is reserved by another app), leaving any prior binding in
    /// place.
    @discardableResult
    func enable() -> Bool {
        installHandlerIfNeeded()
        return register(combo)
    }

    /// Remove the registered hotkey (keeps the persisted combo for next launch).
    func disable() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Swap the binding live and persist it. Returns `false` (and keeps the old
    /// binding) if the new combo can't be registered.
    @discardableResult
    func rebind(to newCombo: Combo) -> Bool {
        let previous = combo
        disable()
        combo = newCombo
        guard register(newCombo) else {
            // Roll back to the previous working binding.
            combo = previous
            _ = register(previous)
            return false
        }
        Self.saveCombo(newCombo)
        return true
    }

    // MARK: Private

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                guard status == noErr else { return status }
                let hotkey = Unmanaged<PetHotkey>.fromOpaque(userData).takeUnretainedValue()
                // The Carbon handler is delivered on the main run loop; hop to the
                // main actor explicitly so we can touch `@MainActor` state safely.
                Task { @MainActor in
                    if firedID.id == hotkey.hotKeyID.id { hotkey.onTrigger() }
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
    }

    @discardableResult
    private func register(_ combo: Combo) -> Bool {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    // MARK: Persistence

    private static func loadCombo() -> Combo? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Combo.self, from: data)
    }

    private static func saveCombo(_ combo: Combo) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
