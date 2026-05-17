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

    var description: String {
        switch self {
        case .accessibilityDenied(let prompt):
            return "accessibility_denied(prompt_shown=\(prompt))"
        case .noConnectedDisplay: return "no_connected_display"
        case .displayBoundsViolation(let x, let y): return "bounds_violation(\(x),\(y))"
        case .eventCreationFailed: return "event_creation_failed"
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

// MARK: - main

let args = CommandLine.arguments
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
