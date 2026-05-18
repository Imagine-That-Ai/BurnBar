import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import OpenBurnBarComputerUseCore

// MARK: - MacInputController (inlined copy from AgentLens)
//
// This CLI is a SwiftPM executable, so it cannot link the AgentLens
// Xcode target where the real `MacInputController` lives. We inline
// the minimum subset needed for the smoke test and delegate the
// virtual-key map + display bounds to `OpenBurnBarComputerUseCore.MacInputCore`
// (same source of truth the AgentLens version uses).

enum CUClickSmokeError: Error, CustomStringConvertible {
    case accessibilityDenied(promptShown: Bool)
    case noConnectedDisplay
    case displayBoundsViolation(Int, Int)
    case eventCreationFailed
    case calculatorLaunchFailed
    case calculatorProcessMissing
    case calculatorResultMismatch(run: Int, observed: [String])

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
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
    return Date().timeIntervalSince(started) * 1000.0
}

func pressKey(_ name: String) throws -> Double {
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
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
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

// MARK: - main

let args = CommandLine.arguments
let runs = args.firstIndex(of: "--runs").flatMap { index -> Int? in
    guard args.count > index + 1 else { return nil }
    return Int(args[index + 1])
} ?? 1

if let scenarioIndex = args.firstIndex(of: "--scenario"), args.count > scenarioIndex + 1 {
    let scenario = args[scenarioIndex + 1]
    print("[cu-click-smoke] AXIsProcessTrusted=\(axTrusted(prompt: false))")
    do {
        switch scenario {
        case "calculator":
            try runCalculatorScenario(runs: runs)
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
