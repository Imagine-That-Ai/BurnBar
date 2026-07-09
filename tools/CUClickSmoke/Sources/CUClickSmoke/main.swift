import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - MacInputController (inlined copy from AgentLens)
//
// This CLI is a SwiftPM executable, so it cannot link the AgentLens
// Xcode target where the real `MacInputController` lives. We inline
// the minimum subset needed for the smoke test.

enum MacInputCore {
    struct DisplayBounds {
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
    }

    enum Modifier {
        case command
        case alternate
        case control
        case shift
        case function
    }

    static func contains(point: (Int, Int), displays: [DisplayBounds]) -> Bool {
        displays.contains { display in
            point.0 >= display.originX
                && point.0 < display.originX + display.width
                && point.1 >= display.originY
                && point.1 < display.originY + display.height
        }
    }

    static func modifiers(for raw: [String]) -> Set<Modifier> {
        var output = Set<Modifier>()
        for value in raw.map({ $0.lowercased() }) {
            switch value {
            case "cmd", "command", "meta": output.insert(.command)
            case "alt", "option", "alternate": output.insert(.alternate)
            case "ctrl", "control": output.insert(.control)
            case "shift": output.insert(.shift)
            case "fn", "function": output.insert(.function)
            default: continue
            }
        }
        return output
    }

    static func virtualKey(for name: String) -> UInt16? {
        let normalized = name.lowercased()
        if normalized.count == 1, let scalar = normalized.unicodeScalars.first {
            switch scalar {
            case "a": return 0x00
            case "b": return 0x0B
            case "c": return 0x08
            case "d": return 0x02
            case "e": return 0x0E
            case "f": return 0x03
            case "g": return 0x05
            case "h": return 0x04
            case "i": return 0x22
            case "j": return 0x26
            case "k": return 0x28
            case "l": return 0x25
            case "m": return 0x2E
            case "n": return 0x2D
            case "o": return 0x1F
            case "p": return 0x23
            case "q": return 0x0C
            case "r": return 0x0F
            case "s": return 0x01
            case "t": return 0x11
            case "u": return 0x20
            case "v": return 0x09
            case "w": return 0x0D
            case "x": return 0x07
            case "y": return 0x10
            case "z": return 0x06
            case "0": return 0x1D
            case "1": return 0x12
            case "2": return 0x13
            case "3": return 0x14
            case "4": return 0x15
            case "5": return 0x17
            case "6": return 0x16
            case "7": return 0x1A
            case "8": return 0x1C
            case "9": return 0x19
            default: break
            }
        }
        switch normalized {
        case "space": return 0x31
        case "escape", "esc": return 0x35
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "delete", "backspace": return 0x33
        default: return nil
        }
    }
}

enum CUClickSmokeError: Error, CustomStringConvertible {
    case accessibilityDenied(promptShown: Bool)
    case noConnectedDisplay
    case displayBoundsViolation(Int, Int)
    case eventCreationFailed
    case calculatorLaunchFailed
    case calculatorProcessMissing
    case calculatorResultMismatch(run: Int, observed: [String])
    case textEditLaunchFailed
    case textEditProcessMissing
    case textEditResultMismatch(run: Int, path: String, reason: String)
    case openBurnBarAppMissing(String)
    case openBurnBarLaunchFailed(String)
    case openBurnBarProcessMissing(String)
    case openBurnBarAXReadinessTimeout(String)
    case screenshotFailed(String)

    var description: String {
        switch self {
        case .accessibilityDenied(let prompt):
            return "accessibility_denied(prompt_shown=\(prompt))"
        case .noConnectedDisplay: return "no_connected_display"
        case .displayBoundsViolation(let x, let y): return "bounds_violation(\(x),\(y))"
        case .eventCreationFailed: return "event_creation_failed"
        case .calculatorLaunchFailed: return "calculator_launch_failed"
        case .calculatorProcessMissing: return "calculator_process_missing"
        case .calculatorResultMismatch(let run, let observed):
            return "calculator_result_mismatch(run=\(run), observed=\(observed.joined(separator: "|")))"
        case .textEditLaunchFailed: return "textedit_launch_failed"
        case .textEditProcessMissing: return "textedit_process_missing"
        case .textEditResultMismatch(let run, let path, let reason):
            return "textedit_result_mismatch(run=\(run), path=\(path), reason=\(reason))"
        case .openBurnBarAppMissing(let path):
            return "openburnbar_app_missing(path=\(path))"
        case .openBurnBarLaunchFailed(let path):
            return "openburnbar_launch_failed(path=\(path))"
        case .openBurnBarProcessMissing(let path):
            return "openburnbar_process_missing(path=\(path))"
        case .openBurnBarAXReadinessTimeout(let details):
            return "openburnbar_ax_readiness_timeout(\(details))"
        case .screenshotFailed(let path):
            return "screenshot_failed(path=\(path))"
        }
    }
}

func connectedDisplayBounds() -> [MacInputCore.DisplayBounds] {
    let totalHeight = NSScreen.screens.first?.frame.maxY ?? 0
    return NSScreen.screens.map { screen in
        let frame = screen.frame
        return MacInputCore.DisplayBounds(
            originX: Int(frame.origin.x),
            originY: Int(totalHeight - frame.maxY),
            width: Int(frame.width),
            height: Int(frame.height)
        )
    }
}

func axTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options: [String: Any] = [key: prompt]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}

func screenCaptureTrusted() -> Bool {
    CGPreflightScreenCaptureAccess()
}

func jsonBool(_ value: Bool) -> String {
    value ? "true" : "false"
}

func printPermissionProbe() {
    print("{\"axTrusted\":\(jsonBool(axTrusted(prompt: false))),\"screenCapture\":\(jsonBool(screenCaptureTrusted()))}")
}

func clickAt(x: Int, y: Int, button: Int = 0) throws -> Double {
    if !axTrusted(prompt: false) {
        let promptShown = !axTrusted(prompt: true)
        throw CUClickSmokeError.accessibilityDenied(promptShown: promptShown)
    }
    let displays = connectedDisplayBounds()
    guard !displays.isEmpty else { throw CUClickSmokeError.noConnectedDisplay }
    guard MacInputCore.contains(point: (x, y), displays: displays) else {
        throw CUClickSmokeError.displayBoundsViolation(x, y)
    }
    let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
    let downType: CGEventType = button == 1 ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = button == 1 ? .rightMouseUp : .leftMouseUp
    let cgButton: CGMouseButton = button == 1 ? .right : .left
    let started = Date()
    guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType,
                                  mouseCursorPosition: position, mouseButton: cgButton),
          let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType,
                                mouseCursorPosition: position, mouseButton: cgButton) else {
        throw CUClickSmokeError.eventCreationFailed
    }
    downEvent.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    upEvent.post(tap: .cghidEventTap)
    return Date().timeIntervalSince(started) * 1000.0
}

func typeText(_ text: String) throws -> Double {
    if !axTrusted(prompt: false) {
        let promptShown = !axTrusted(prompt: true)
        throw CUClickSmokeError.accessibilityDenied(promptShown: promptShown)
    }
    let started = Date()
    for char in text {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw CUClickSmokeError.eventCreationFailed
        }
        var chars = Array(String(char).utf16)
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
    return Date().timeIntervalSince(started) * 1000.0
}

func cgFlags(for modifiers: [String]) -> CGEventFlags {
    let normalized = MacInputCore.modifiers(for: modifiers)
    var flags: CGEventFlags = []
    if normalized.contains(.command) { flags.insert(.maskCommand) }
    if normalized.contains(.alternate) { flags.insert(.maskAlternate) }
    if normalized.contains(.control) { flags.insert(.maskControl) }
    if normalized.contains(.shift) { flags.insert(.maskShift) }
    if normalized.contains(.function) { flags.insert(.maskSecondaryFn) }
    return flags
}

func pressKey(_ name: String, modifiers: [String] = []) throws -> Double {
    if !axTrusted(prompt: false) {
        let promptShown = !axTrusted(prompt: true)
        throw CUClickSmokeError.accessibilityDenied(promptShown: promptShown)
    }
    guard let keyCode = MacInputCore.virtualKey(for: name),
          let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
        throw CUClickSmokeError.eventCreationFailed
    }
    let started = Date()
    let flags = cgFlags(for: modifiers)
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return Date().timeIntervalSince(started) * 1000.0
}

func typeKeyText(_ text: String) throws -> Double {
    let started = Date()
    for char in text {
        switch char {
        case "a"..."z", "0"..."9":
            _ = try pressKey(String(char))
        case " ":
            _ = try pressKey("space")
        default:
            _ = try typeText(String(char))
        }
        Thread.sleep(forTimeInterval: 0.025)
    }
    return Date().timeIntervalSince(started) * 1000.0
}

@discardableResult
func launchCalculator() throws -> NSRunningApplication {
    let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true)
    guard NSWorkspace.shared.open(calculatorURL) else {
        throw CUClickSmokeError.calculatorLaunchFailed
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.calculator" || $0.bundleIdentifier == "com.apple.Calculator"
        }) {
            app.activate(options: [.activateAllWindows])
            Thread.sleep(forTimeInterval: 0.3)
            return app
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    throw CUClickSmokeError.calculatorProcessMissing
}

func calculatorTextSnapshot(app: NSRunningApplication) -> [String] {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var seen = Set<CFHashCode>()
    var output: [String] = []

    func collect(_ element: AXUIElement, depth: Int) {
        if depth > 8 { return }
        let key = CFHash(element)
        if seen.contains(key) { return }
        seen.insert(key)

        let attributes = [
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXRoleDescriptionAttribute
        ]
        for attribute in attributes {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { output.append(trimmed) }
            }
        }

        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let elements = children as? [AXUIElement] {
            for child in elements { collect(child, depth: depth + 1) }
        }
    }

    collect(root, depth: 0)
    return Array(Set(output)).sorted()
}

func runCalculatorScenario(runs: Int) throws {
    let app = try launchCalculator()
    var durations: [Double] = []
    var failures = 0

    for run in 1...runs {
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.15)
        _ = try? pressKey("escape")
        Thread.sleep(forTimeInterval: 0.05)
        let elapsed = try typeText("2+2=")
        Thread.sleep(forTimeInterval: 0.2)
        let observed = calculatorTextSnapshot(app: app)
        let pass = observed.contains { text in
            let normalized = text
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == "4" || normalized == "4.0" || normalized == "4.00"
        }
        if pass {
            durations.append(elapsed)
            print("[cu-click-smoke] calculator run \(run)/\(runs) PASS in \(String(format: "%.2f", elapsed)) ms")
        } else {
            failures += 1
            print("[cu-click-smoke] calculator run \(run)/\(runs) FAIL observed=\(observed)")
        }
    }

    let sorted = durations.sorted()
    let p50 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count / 2)]
    let p95Index = sorted.isEmpty ? 0 : min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))
    let p95 = sorted.isEmpty ? 0 : sorted[p95Index]
    print("[cu-click-smoke] calculator summary pass=\(durations.count) fail=\(failures) p50_ms=\(String(format: "%.2f", p50)) p95_ms=\(String(format: "%.2f", p95))")
    if failures > 0 {
        throw CUClickSmokeError.calculatorResultMismatch(run: failures, observed: calculatorTextSnapshot(app: app))
    }
}

@discardableResult
func launchTextEdit(fileURL: URL) throws -> NSRunningApplication {
    let existingPids = Set(NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == "com.apple.TextEdit" }
        .map(\.processIdentifier))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", "-a", "TextEdit", fileURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CUClickSmokeError.textEditLaunchFailed
    }

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.TextEdit" && !existingPids.contains($0.processIdentifier)
        }) {
            app.activate(options: [.activateAllWindows])
            Thread.sleep(forTimeInterval: 0.7)
            return app
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    throw CUClickSmokeError.textEditProcessMissing
}

func focusedWindowCenter(app: NSRunningApplication) -> (x: Int, y: Int)? {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var focusedWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindow
    ) == .success, let window = focusedWindow else {
        return nil
    }

    guard CFGetTypeID(window) == AXUIElementGetTypeID() else {
        FileHandle.standardError.write(Data("CUClickSmoke: focused window attribute is not an AXUIElement\n".utf8))
        return nil
    }
    let windowElement = unsafeDowncast(window, to: AXUIElement.self)
    AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)

    var targetPosition = CGPoint(x: 120, y: 120)
    var targetSize = CGSize(width: 900, height: 700)
    if let positionValue = AXValueCreate(.cgPoint, &targetPosition) {
        AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &targetSize) {
        AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
    }
    Thread.sleep(forTimeInterval: 0.08)

    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &rawPosition) == .success,
          AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &rawSize) == .success,
          let positionValue = rawPosition,
          let sizeValue = rawSize else {
        return nil
    }

    guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        FileHandle.standardError.write(Data("CUClickSmoke: window position/size attributes are not AXValues\n".utf8))
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else {
        return nil
    }
    return (
        x: Int(position.x + size.width / 2),
        y: Int(position.y + min(size.height - 80, size.height / 2))
    )
}

func runTextEditScenario(runs: Int) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("openburnbar-cu-textedit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var durations: [Double] = []
    var failures = 0

    for run in 1...runs {
        let text = "openburnbar textedit loopback run \(run)"
        let expectedFragment = "textedit loopback run \(run)"
        let fileURL = directory.appendingPathComponent("run-\(String(format: "%03d", run)).rtf")
        try "{\\rtf1\\ansi\\deff0\n}\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let app = try launchTextEdit(fileURL: fileURL)
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.45)
        if let center = focusedWindowCenter(app: app) {
            _ = try clickAt(x: center.x, y: center.y)
            Thread.sleep(forTimeInterval: 0.2)
        }

        let started = Date()
        _ = try pressKey("a", modifiers: ["cmd"])
        Thread.sleep(forTimeInterval: 0.04)
        _ = try pressKey("b", modifiers: ["cmd"])
        Thread.sleep(forTimeInterval: 0.04)
        _ = try typeKeyText(text)
        Thread.sleep(forTimeInterval: 0.05)
        _ = try pressKey("s", modifiers: ["cmd"])
        let elapsed = Date().timeIntervalSince(started) * 1000.0

        var contents = ""
        var hasText = false
        var hasBoldMarker = false
        let deadline = Date().addingTimeInterval(2)
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            hasText = contents.contains(expectedFragment)
            hasBoldMarker = contents.contains("\\b") || contents.contains("\\b0")
        } while Date() < deadline && !(hasText && hasBoldMarker)

        let pass = hasText && hasBoldMarker
        if pass {
            durations.append(elapsed)
            print("[cu-click-smoke] textedit run \(run)/\(runs) PASS in \(String(format: "%.2f", elapsed)) ms")
        } else {
            failures += 1
            let reason = "hasText=\(hasText), hasBoldMarker=\(hasBoldMarker)"
            print("[cu-click-smoke] textedit run \(run)/\(runs) FAIL \(reason) path=\(fileURL.path)")
        }

        if pass {
            _ = try? pressKey("w", modifiers: ["cmd"])
            Thread.sleep(forTimeInterval: 0.2)
        }
        app.terminate()
        Thread.sleep(forTimeInterval: 0.15)
    }

    let sorted = durations.sorted()
    let p50 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count / 2)]
    let p95Index = sorted.isEmpty ? 0 : min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))
    let p95 = sorted.isEmpty ? 0 : sorted[p95Index]
    print("[cu-click-smoke] textedit summary pass=\(durations.count) fail=\(failures) p50_ms=\(String(format: "%.2f", p50)) p95_ms=\(String(format: "%.2f", p95)) dir=\(directory.path)")
    if failures > 0 {
        throw CUClickSmokeError.textEditResultMismatch(run: failures, path: directory.path, reason: "one_or_more_runs_failed")
    }
}

struct AXSnapshot {
    var roles: Set<String> = []
    var texts: Set<String> = []
    var elementCount = 0

    var summary: String {
        let roleList = roles.sorted().prefix(10).joined(separator: "|")
        let textList = texts.sorted().prefix(10).joined(separator: "|")
        return "elements=\(elementCount), roles=\(roleList), texts=\(textList)"
    }
}

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let string = value as? String else {
        return nil
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func snapshotAXTree(root: AXUIElement, maxDepth: Int = 8, maxElements: Int = 900) -> AXSnapshot {
    var snapshot = AXSnapshot()
    var seen = Set<CFHashCode>()

    func collect(_ element: AXUIElement, depth: Int) {
        if depth > maxDepth || snapshot.elementCount >= maxElements { return }
        let key = CFHash(element)
        if seen.contains(key) { return }
        seen.insert(key)
        snapshot.elementCount += 1

        if let role = stringAttribute(element, kAXRoleAttribute) {
            snapshot.roles.insert(role)
        }
        for attribute in [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXRoleDescriptionAttribute,
            kAXIdentifierAttribute,
            kAXValueAttribute
        ] {
            if let text = stringAttribute(element, attribute) {
                snapshot.texts.insert(text)
            }
        }

        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let elements = children as? [AXUIElement] {
            for child in elements {
                collect(child, depth: depth + 1)
            }
        }
    }

    collect(root, depth: 0)
    return snapshot
}

func runningOpenBurnBarApp(appURL: URL) -> NSRunningApplication? {
    let standardized = appURL.standardizedFileURL
    return NSWorkspace.shared.runningApplications.first { app in
        if app.bundleIdentifier == "com.openburnbar.app" { return true }
        if let bundleURL = app.bundleURL?.standardizedFileURL, bundleURL == standardized { return true }
        return false
    }
}

@discardableResult
func launchOpenBurnBar(appURL: URL) throws -> NSRunningApplication {
    guard FileManager.default.fileExists(atPath: appURL.path) else {
        throw CUClickSmokeError.openBurnBarAppMissing(appURL.path)
    }

    if let existing = runningOpenBurnBarApp(appURL: appURL) {
        existing.activate(options: [.activateAllWindows])
        return existing
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [appURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CUClickSmokeError.openBurnBarLaunchFailed(appURL.path)
    }

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let app = runningOpenBurnBarApp(appURL: appURL) {
            app.activate(options: [.activateAllWindows])
            return app
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    throw CUClickSmokeError.openBurnBarProcessMissing(appURL.path)
}

func systemUIServerStatusItemSnapshot() -> AXSnapshot {
    guard let systemUIServer = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.systemuiserver"
    }) else {
        return AXSnapshot()
    }
    return snapshotAXTree(root: AXUIElementCreateApplication(systemUIServer.processIdentifier), maxDepth: 10, maxElements: 1_500)
}

func containsOpenBurnBarStatusItem(_ snapshot: AXSnapshot) -> Bool {
    snapshot.texts.contains { text in
        text.localizedCaseInsensitiveContains("OpenBurnBar")
    }
}

func containsOpenBurnBarDashboardRoot(_ snapshot: AXSnapshot) -> Bool {
    let hasApplicationRoot = snapshot.roles.contains(kAXApplicationRole as String)
    let hasWindow = snapshot.roles.contains(kAXWindowRole as String)
    let hasKnownRootText = snapshot.texts.contains { text in
        let lowercased = text.lowercased()
        return lowercased.contains("openburnbar")
            || lowercased.contains("dashboard")
            || lowercased.contains("burn")
            || lowercased.contains("hermes")
            || lowercased.contains("settings")
    }
    return hasApplicationRoot && (hasWindow || hasKnownRootText)
}

func captureScreenshot(path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CUClickSmokeError.screenshotFailed(path)
    }
}

func runOpenBurnBarScenario(appPath: String, evidencePath: String?) throws {
    if !axTrusted(prompt: false) {
        let promptShown = !axTrusted(prompt: true)
        throw CUClickSmokeError.accessibilityDenied(promptShown: promptShown)
    }

    let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
    let app = try launchOpenBurnBar(appURL: appURL)
    defer {
        app.terminate()
        let deadline = Date().addingTimeInterval(4)
        while !app.isTerminated && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if !app.isTerminated {
            app.forceTerminate()
        }
    }

    var lastAppSnapshot = AXSnapshot()
    var lastStatusSnapshot = AXSnapshot()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        app.activate(options: [.activateAllWindows])
        lastAppSnapshot = snapshotAXTree(root: AXUIElementCreateApplication(app.processIdentifier))
        lastStatusSnapshot = systemUIServerStatusItemSnapshot()

        let hasRoot = containsOpenBurnBarDashboardRoot(lastAppSnapshot)
        let hasStatusItem = containsOpenBurnBarStatusItem(lastStatusSnapshot)
        if hasRoot || hasStatusItem {
            print("[cu-click-smoke] openburnbar AX ready root=\(hasRoot) statusItem=\(hasStatusItem)")
            print("[cu-click-smoke] openburnbar app snapshot \(lastAppSnapshot.summary)")
            if let evidencePath {
                try captureScreenshot(path: evidencePath)
                print("[cu-click-smoke] openburnbar screenshot=\(evidencePath)")
            }
            return
        }

        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }

    throw CUClickSmokeError.openBurnBarAXReadinessTimeout(
        "app{\(lastAppSnapshot.summary)} systemuiserver{\(lastStatusSnapshot.summary)}"
    )
}

// MARK: - main

let args = CommandLine.arguments
if args.contains("--probe-permissions") {
    printPermissionProbe()
    exit(0)
}

let runs = args.firstIndex(of: "--runs").flatMap { index -> Int? in
    guard args.count > index + 1 else { return nil }
    return Int(args[index + 1])
} ?? 1

func argumentValue(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
    return args[index + 1]
}

if let scenarioIndex = args.firstIndex(of: "--scenario"), args.count > scenarioIndex + 1 {
    let scenario = args[scenarioIndex + 1]
    print("[cu-click-smoke] AXIsProcessTrusted=\(axTrusted(prompt: false))")
    print("[cu-click-smoke] CGPreflightScreenCaptureAccess=\(screenCaptureTrusted())")
    do {
        switch scenario {
        case "calculator":
            try runCalculatorScenario(runs: runs)
        case "textedit":
            try runTextEditScenario(runs: runs)
        case "openburnbar":
            guard let appPath = argumentValue("--app-path") else {
                print("[cu-click-smoke] FAIL openburnbar_missing_app_path")
                exit(4)
            }
            try runOpenBurnBarScenario(appPath: appPath, evidencePath: argumentValue("--evidence-path"))
        default:
            print("[cu-click-smoke] FAIL unknown_scenario=\(scenario)")
            exit(4)
        }
        exit(0)
    } catch CUClickSmokeError.accessibilityDenied(let promptShown) {
        print("[cu-click-smoke] FAIL accessibility_not_granted (prompt_shown=\(promptShown))")
        print("[cu-click-smoke] Grant in: System Settings → Privacy & Security → Accessibility → enable this terminal binary, then re-run.")
        exit(2)
    } catch {
        print("[cu-click-smoke] FAIL \(error)")
        exit(3)
    }
}

let target: (x: Int, y: Int)
if let xs = args.firstIndex(of: "--x"), args.count > xs + 1,
   let ys = args.firstIndex(of: "--y"), args.count > ys + 1,
   let x = Int(args[xs + 1]), let y = Int(args[ys + 1]) {
    target = (x, y)
} else {
    // Default: click in the middle of the primary display.
    let displays = connectedDisplayBounds()
    if let primary = displays.first {
        target = (primary.originX + primary.width / 2, primary.originY + primary.height / 2)
    } else {
        target = (640, 400)
    }
}

print("[cu-click-smoke] target=(\(target.x), \(target.y))")
print("[cu-click-smoke] AXIsProcessTrusted=\(axTrusted(prompt: false))")

do {
    let ms = try clickAt(x: target.x, y: target.y)
    print("[cu-click-smoke] OK click posted in \(String(format: "%.2f", ms)) ms")
    exit(0)
} catch CUClickSmokeError.accessibilityDenied(let promptShown) {
    print("[cu-click-smoke] FAIL accessibility_not_granted (prompt_shown=\(promptShown))")
    print("[cu-click-smoke] Grant in: System Settings → Privacy & Security → Accessibility → enable this terminal binary, then re-run.")
    exit(2)
} catch {
    print("[cu-click-smoke] FAIL \(error)")
    exit(3)
}
