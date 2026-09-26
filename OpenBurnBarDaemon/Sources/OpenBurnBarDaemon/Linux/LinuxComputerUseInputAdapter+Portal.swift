#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine

extension LinuxComputerUseInputAdapter {
    func portalNotifyCommands(
        for action: MacInputAction,
        sessionHandle: String
    ) throws -> [[String]] {
        switch action.kind {
        case .click, .pointerClick:
            var commands: [[String]] = []
            if action.kind == .click {
                guard let x = action.displayX, let y = action.displayY else {
                    throw AdapterError.missingCoordinate("portal click requires displayX and displayY")
                }
                commands.append(portalNotifyAbsoluteMotion(
                    sessionHandle: sessionHandle,
                    x: x,
                    y: y
                ))
            }
            let button = portalButtonCode(action.mouseButton)
            commands.append(portalNotifyButton(
                sessionHandle: sessionHandle,
                button: button,
                state: 1
            ))
            commands.append(portalNotifyButton(
                sessionHandle: sessionHandle,
                button: button,
                state: 0
            ))
            return commands

        case .pointerMove:
            if action.deltaX != nil || action.deltaY != nil {
                return [portalNotifyRelativeMotion(
                    sessionHandle: sessionHandle,
                    deltaX: action.deltaX ?? 0,
                    deltaY: action.deltaY ?? 0
                )]
            }
            guard let x = action.displayX, let y = action.displayY else {
                throw AdapterError.missingCoordinate("portal pointer_move requires displayX and displayY")
            }
            return [portalNotifyAbsoluteMotion(
                sessionHandle: sessionHandle,
                x: x,
                y: y
            )]

        case .scroll:
            var commands: [[String]] = []
            if let x = action.displayX, let y = action.displayY {
                commands.append(portalNotifyAbsoluteMotion(
                    sessionHandle: sessionHandle,
                    x: x,
                    y: y
                ))
            }
            let deltaX = action.deltaX ?? 0
            let deltaY = action.deltaY ?? 0
            guard deltaX != 0 || deltaY != 0 else {
                throw AdapterError.unsupportedAction("portal scroll requires non-zero deltaX or deltaY")
            }
            commands.append(portalNotifyAxis(
                sessionHandle: sessionHandle,
                deltaX: deltaX,
                deltaY: deltaY
            ))
            return commands

        case .dragDrop:
            guard let startX = action.displayX,
                  let startY = action.displayY,
                  let endX = action.dragEndX,
                  let endY = action.dragEndY else {
                throw AdapterError.missingCoordinate("portal drag_drop requires displayX, displayY, dragEndX, and dragEndY")
            }
            let button = portalButtonCode(action.mouseButton)
            return [
                portalNotifyAbsoluteMotion(sessionHandle: sessionHandle, x: startX, y: startY),
                portalNotifyButton(sessionHandle: sessionHandle, button: button, state: 1),
                portalNotifyAbsoluteMotion(sessionHandle: sessionHandle, x: endX, y: endY),
                portalNotifyButton(sessionHandle: sessionHandle, button: button, state: 0)
            ]

        case .key:
            guard let key = action.key,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdapterError.unsupportedAction("portal key requires key")
            }
            let keysym = try portalKeysym(for: key)
            return portalKeyCommands(sessionHandle: sessionHandle, keysyms: [keysym])

        case .shortcut:
            guard let key = action.key,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdapterError.unsupportedAction("portal shortcut requires key")
            }
            let modifiers = try (action.modifiers ?? []).map(portalKeysym(for:))
            let keySym = try portalKeysym(for: key)
            return portalKeyCommands(
                sessionHandle: sessionHandle,
                keysyms: modifiers + [keySym]
            )

        case .type:
            guard let text = action.text, !text.isEmpty else {
                throw AdapterError.unsupportedAction("portal type requires non-empty text")
            }
            guard text.count <= 4_096 else {
                throw AdapterError.unsupportedAction("portal type exceeds the 4096-character event bound")
            }
            var commands: [[String]] = []
            for scalar in text.unicodeScalars {
                let keysym = try portalKeysym(for: String(scalar))
                commands.append(contentsOf: portalKeyCommands(
                    sessionHandle: sessionHandle,
                    keysyms: [keysym]
                ))
            }
            return commands
        }
    }

    private func portalNotifyAbsoluteMotion(
        sessionHandle: String,
        x: Int,
        y: Int
    ) -> [String] {
        portalCall(
            method: "NotifyPointerMotionAbsolute",
            sessionHandle: sessionHandle,
            arguments: ["{}", portalStreamID(), String(x), String(y)]
        )
    }

    private func portalNotifyRelativeMotion(
        sessionHandle: String,
        deltaX: Int,
        deltaY: Int
    ) -> [String] {
        portalCall(
            method: "NotifyPointerMotion",
            sessionHandle: sessionHandle,
            arguments: ["{}", String(deltaX), String(deltaY)]
        )
    }

    private func portalNotifyButton(
        sessionHandle: String,
        button: Int,
        state: Int
    ) -> [String] {
        portalCall(
            method: "NotifyPointerButton",
            sessionHandle: sessionHandle,
            arguments: ["{}", String(button), String(state)]
        )
    }

    private func portalNotifyAxis(
        sessionHandle: String,
        deltaX: Int,
        deltaY: Int
    ) -> [String] {
        portalCall(
            method: "NotifyPointerAxis",
            sessionHandle: sessionHandle,
            arguments: ["{}", String(deltaX), String(deltaY)]
        )
    }

    private func portalKeyCommands(
        sessionHandle: String,
        keysyms: [Int]
    ) -> [[String]] {
        var commands: [[String]] = []
        for keysym in keysyms {
            commands.append(portalCall(
                method: "NotifyKeyboardKeysym",
                sessionHandle: sessionHandle,
                arguments: ["{}", String(keysym), "1"]
            ))
        }
        for keysym in keysyms.reversed() {
            commands.append(portalCall(
                method: "NotifyKeyboardKeysym",
                sessionHandle: sessionHandle,
                arguments: ["{}", String(keysym), "0"]
            ))
        }
        return commands
    }

    private func portalCall(
        method: String,
        sessionHandle: String,
        arguments: [String]
    ) -> [String] {
        [
            "call", "--session",
            "--dest", Self.portalBusName,
            "--object-path", sessionHandle,
            "--method", "\(Self.remoteDesktopInterface).\(method)",
            sessionHandle
        ] + arguments
    }

    private func portalStreamID() -> String {
        guard let raw = nonEmptyEnvironment("OPENBURNBAR_LINUX_CU_PORTAL_STREAM_ID"),
              let stream = UInt32(raw) else {
            return "0"
        }
        return String(stream)
    }

    private func portalButtonCode(_ mouseButton: Int) -> Int {
        switch mouseButton {
        case 1: return 0x111 // BTN_RIGHT
        case 2: return 0x112 // BTN_MIDDLE
        default: return 0x110 // BTN_LEFT
        }
    }

    private func portalKeysym(for rawKey: String) throws -> Int {
        if rawKey.unicodeScalars.count == 1,
           let scalar = rawKey.unicodeScalars.first {
            switch scalar.value {
            case 0x09: return 0xff09 // tab
            case 0x0a: return 0xff0a // line feed
            case 0x0d: return 0xff0d // carriage return
            default:
                if scalar.value <= 0x7f {
                    return Int(scalar.value)
                }
                return 0x0100_0000 | Int(scalar.value)
            }
        }
        let normalized = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AdapterError.unsupportedAction("portal key is empty")
        }
        switch normalized.lowercased() {
        case "return", "enter": return 0xff0d
        case "escape", "esc": return 0xff1b
        case "delete": return 0xffff
        case "backspace": return 0xff08
        case "tab": return 0xff09
        case "space": return 0x20
        case "left", "arrowleft": return 0xff51
        case "up", "arrowup": return 0xff52
        case "right", "arrowright": return 0xff53
        case "down", "arrowdown": return 0xff54
        case "home": return 0xff50
        case "end": return 0xff57
        case "pageup": return 0xff55
        case "pagedown": return 0xff56
        case "insert": return 0xff63
        case "control", "ctrl": return 0xffe3
        case "command", "cmd", "super", "meta": return 0xffeb
        case "alternate", "option", "alt": return 0xffe9
        case "shift": return 0xffe1
        default:
            let uppercased = normalized.uppercased()
            if let functionNumber = Int(uppercased.dropFirst()),
               uppercased.first == "F",
               (1...24).contains(functionNumber) {
                return 0xffbe + functionNumber - 1
            }
            guard normalized.unicodeScalars.count == 1,
                  let scalar = normalized.unicodeScalars.first else {
                throw AdapterError.unsupportedAction("portal key is not a supported keysym")
            }
            // X11's Unicode keysym encoding keeps non-ASCII input
            // deterministic without consulting a keyboard layout.
            return scalar.value <= 0x7f
                ? Int(scalar.value)
                : 0x0100_0000 | Int(scalar.value)
        }
    }

    struct PortalResponse: Sendable {
        let code: UInt32
        let output: String
    }

    func issueRemoteDesktopRequest(
        method: String,
        arguments: [String]
    ) throws -> String {
        let result = try runFixedPortalCommand(
            [
                "call", "--session",
                "--dest", Self.portalBusName,
                "--object-path", Self.portalObjectPath,
                "--method", "\(Self.remoteDesktopInterface).\(method)"
            ] + arguments,
            timeoutMillis: portalProbeTimeoutMillis
        )
        guard result.exitCode == 0 else {
            throw portalCommandError(operation: portalOperationName(method), exitCode: result.exitCode)
        }
        guard let requestPath = parsePortalObjectPath(result.stdout, requiredComponent: "request") else {
            throw AdapterError.portalUnavailable("remote_desktop_\(portalOperationName(method))_request_handle_missing")
        }
        return requestPath
    }

    func waitForRemoteDesktopResponse(requestPath: String) throws -> PortalResponse {
        guard let validatedRequest = parsePortalObjectPath(
            requestPath,
            requiredComponent: "request"
        ) else {
            throw AdapterError.portalUnavailable("remote_desktop_request_handle_invalid")
        }
        let result = try runFixedPortalCommand(
            [
                "monitor", "--session",
                "--dest", Self.portalBusName,
                "--object-path", validatedRequest
            ],
            timeoutMillis: portalSessionTimeoutMillis
        )
        let boundedOutput = String(result.stdout.prefix(16_384))
        if let code = parsePortalResponseCode(boundedOutput) {
            return PortalResponse(code: code, output: boundedOutput)
        }
        if result.exitCode == 124 {
            throw AdapterError.portalTimedOut
        }
        if result.exitCode == 130 {
            throw AdapterError.portalCancelled
        }
        throw AdapterError.portalUnavailable("remote_desktop_portal_response_missing")
    }

    func runFixedPortalCommand(
        _ arguments: [String],
        timeoutMillis: Int,
        allowWhenKillSwitchActive: Bool = false
    ) throws -> CommandResult {
        try Task.checkCancellation()
        if !allowWhenKillSwitchActive {
            try assertKillSwitchNotActive()
        }
        guard let gdbus = resolveExecutable("gdbus") else {
            throw AdapterError.portalUnavailable("gdbus_unavailable")
        }
        let result: CommandResult
        do {
            result = try runPortalProbe(gdbus, arguments, max(1, timeoutMillis))
        } catch is CancellationError {
            throw AdapterError.portalCancelled
        } catch {
            throw AdapterError.portalUnavailable("remote_desktop_portal_command_failed")
        }
        try Task.checkCancellation()
        if !allowWhenKillSwitchActive {
            try assertKillSwitchNotActive()
        }
        return result
    }

    func portalCommandError(operation: String, exitCode: Int32) -> AdapterError {
        switch exitCode {
        case 124:
            return .portalTimedOut
        case 130:
            return .portalCancelled
        case 1, 2:
            return .portalDenied("remote_desktop_\(operation)_denied")
        default:
            return .portalUnavailable("remote_desktop_\(operation)_failed")
        }
    }

    func portalResponseError(operation: String, code: UInt32) -> AdapterError {
        switch code {
        case 1:
            return .portalDenied("remote_desktop_\(operation)_denied")
        case 2:
            return .portalCancelled
        default:
            return .portalUnavailable("remote_desktop_\(operation)_failed")
        }
    }

    private func parsePortalResponseCode(_ output: String) -> UInt32? {
        guard let responseRange = output.range(of: "Response") else {
            return nil
        }
        let responseOutput = output[responseRange.upperBound...]
        for code: UInt32 in 0...2 where responseOutput.contains("uint32 \(code)") {
            return code
        }
        return nil
    }

    func parsePortalObjectPath(
        _ output: String,
        requiredComponent: String
    ) -> String? {
        let candidates = output.split { character in
            character.isWhitespace || "()<>',\";".contains(character)
        }
        for candidate in candidates {
            guard candidate.hasPrefix("/org/freedesktop/portal/desktop/") else {
                continue
            }
            let path = String(candidate)
            guard path.count <= 256,
                  path.contains("/\(requiredComponent)/"),
                  path.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII && (scalar.value == 47 || scalar.value == 95 ||
                          (scalar.value >= 48 && scalar.value <= 57) ||
                          (scalar.value >= 65 && scalar.value <= 90) ||
                          (scalar.value >= 97 && scalar.value <= 122))
                  }) else {
                continue
            }
            return path
        }
        return nil
    }

    func portalToken(prefix: String) -> String {
        "openburnbar_\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    func closeRemoteDesktopSessionBestEffort(_ sessionHandle: String) {
        guard let validatedHandle = parsePortalObjectPath(
            sessionHandle,
            requiredComponent: "session"
        ) else {
            return
        }
        _ = try? runFixedPortalCommand(
            [
                "call", "--session",
                "--dest", Self.portalBusName,
                "--object-path", validatedHandle,
                "--method", "\(Self.sessionInterface).Close"
            ],
            timeoutMillis: portalProbeTimeoutMillis,
            allowWhenKillSwitchActive: true
        )
    }

    private func portalOperationName(_ method: String) -> String {
        switch method {
        case "CreateSession": return "create_session"
        case "SelectDevices": return "select_devices"
        case "Start": return "start_session"
        default: return "request"
        }
    }
}
#endif
