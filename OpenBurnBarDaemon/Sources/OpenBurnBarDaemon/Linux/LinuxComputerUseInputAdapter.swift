#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

enum LinuxPrivilegedInputKillFlag {
    static let legacyProductionFlagPath = "/var/run/openburnbar-privileged-input-kill"
    private static let flagFilename = "privileged-input-kill"

    static var flagPath: String {
        resolvedFlagPath(environment: { ProcessInfo.processInfo.environment[$0] })
    }

    static func resolvedFlagPath(environment: (String) -> String?) -> String {
        overrideFlagPath(environment: environment)
            ?? runtimeFlagPath(environment: environment)
            ?? legacyProductionFlagPath
    }

    static func activeFlagPaths(environment: (String) -> String?) -> [String] {
        if let override = overrideFlagPath(environment: environment) {
            return [override]
        }
        var paths: [String] = []
        if let runtime = runtimeFlagPath(environment: environment) {
            paths.append(runtime)
        }
        paths.append(legacyProductionFlagPath)
        var uniquePaths: [String] = []
        for path in paths where !uniquePaths.contains(path) {
            uniquePaths.append(path)
        }
        return uniquePaths
    }

    static func activate(reason: String) {
        do {
            let flagURL = URL(fileURLWithPath: flagPath)
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try reason.write(to: flagURL, atomically: true, encoding: .utf8)
        } catch {
            let message = "LinuxPrivilegedInputKillFlag.activate failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    static func isActive(
        environment: (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        activeFlagPaths(environment: environment).contains(where: fileExists)
    }

    static func environmentKillSwitchActive(
        environment: (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) -> Bool {
        [
            "OPENBURNBAR_COMPUTER_USE_KILL_SWITCH",
            "COMPUTER_USE_KILL_SWITCH",
            "computer_use_kill_switch"
        ].contains { name in
            guard let value = nonEmpty(environment(name))?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(value)
        }
    }

    private static func overrideFlagPath(environment: (String) -> String?) -> String? {
        nonEmpty(environment("OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH"))
    }

    private static func runtimeFlagPath(environment: (String) -> String?) -> String? {
        guard let runtimeDirectory = nonEmpty(environment("XDG_RUNTIME_DIR")) else {
            return nil
        }
        return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("openburnbar", isDirectory: true)
            .appendingPathComponent(flagFilename, isDirectory: false)
            .path
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct LinuxComputerUseInputAdapter: Sendable {
    public enum AdapterID: String, Codable, Equatable, Sendable {
        case atspi2 = "at-spi2"
        case x11XTest = "x11-xtest"
    }

    public enum AdapterError: Error, Equatable, CustomStringConvertible {
        case adapterUnavailable(String)
        case missingCoordinate(String)
        case unsupportedAction(String)
        case killSwitchActive(String)
        case commandFailed(adapter: String, exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .adapterUnavailable(let detail):
                return "linux_input_adapter_unavailable: \(detail)"
            case .missingCoordinate(let detail):
                return "linux_input_missing_coordinate: \(detail)"
            case .unsupportedAction(let detail):
                return "linux_input_unsupported_action: \(detail)"
            case .killSwitchActive(let detail):
                return "linux_input_kill_switch_active: \(detail)"
            case .commandFailed(let adapter, let exitCode, let stderr):
                return "linux_input_command_failed adapter=\(adapter) exit=\(exitCode) stderr=\(stderr)"
            }
        }
    }

    public enum AccessibilityInspection: Equatable, Sendable {
        case clear
        case denied(ComputerUseAccessibilityDenyReason)
        case uninspectable(String)
    }

    public struct CommandResult: Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String

        public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public struct DispatchPlan: Sendable, Equatable {
        public var adapter: AdapterID
        public var executablePath: String
        public var executableName: String
        public var arguments: [String]

        public init(
            adapter: AdapterID,
            executablePath: String,
            executableName: String,
            arguments: [String]
        ) {
            self.adapter = adapter
            self.executablePath = executablePath
            self.executableName = executableName
            self.arguments = arguments
        }
    }

    public typealias EnvironmentReader = @Sendable (_ name: String) -> String?
    public typealias ExecutableResolver = @Sendable (_ name: String) -> String?
    public typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) throws -> CommandResult

    private let environment: EnvironmentReader
    private let resolveExecutable: ExecutableResolver
    private let runCommand: CommandRunner

    private enum DenyRegionTarget {
        case clear
        case focus
        case points([(x: Int, y: Int)])
        case uninspectable(String)
    }

    init(
        environment: @escaping EnvironmentReader = { ProcessInfo.processInfo.environment[$0] },
        resolveExecutable: @escaping ExecutableResolver = LinuxComputerUseInputAdapter.which,
        runCommand: @escaping CommandRunner = LinuxComputerUseInputAdapter.runProcess
    ) {
        self.environment = environment
        self.resolveExecutable = resolveExecutable
        self.runCommand = runCommand
    }

    public func isAvailableForSystemInput() -> Bool {
        atspi2Available() || x11XTestAvailable()
    }

    public func dispatch(_ action: MacInputAction) async throws -> BurnBarJSONValue {
        try assertKillSwitchNotActive()
        let plan = try plan(for: action)
        let startedAt = Date()
        let result = try runCommand(plan.executablePath, plan.arguments)
        let durationMs = Date().timeIntervalSince(startedAt) * 1000
        guard result.exitCode == 0 else {
            throw AdapterError.commandFailed(
                adapter: plan.adapter.rawValue,
                exitCode: result.exitCode,
                stderr: String(result.stderr.prefix(2048))
            )
        }

        return .object([
            "platform": .string("linux"),
            "adapter": .string(plan.adapter.rawValue),
            "kind": .string(action.kind.rawValue),
            "command": .string(plan.executableName),
            "durationMs": .number(durationMs),
            "exitCode": .number(Double(result.exitCode)),
            "stdout": .string(String(result.stdout.prefix(2048))),
            "stderr": .string(String(result.stderr.prefix(2048))),
            "textLength": action.text.map { .number(Double($0.count)) } ?? .null,
            "displayX": action.displayX.map { .number(Double($0)) } ?? .null,
            "displayY": action.displayY.map { .number(Double($0)) } ?? .null
        ])
    }

    public func inspectAccessibility(_ action: MacInspectAction) async throws -> BurnBarJSONValue {
        .object([
            "platform": .string("linux"),
            "adapter": atspi2Available() ? .string(AdapterID.atspi2.rawValue) : .null,
            "kind": .string(action.kind.rawValue),
            "available": .bool(atspi2Available()),
            "dbusSession": .bool(nonEmptyEnvironment("DBUS_SESSION_BUS_ADDRESS") != nil),
            "atspiBus": .bool(nonEmptyEnvironment("AT_SPI_BUS_ADDRESS") != nil),
            "python3": .bool(resolveExecutable("python3") != nil)
        ])
    }

    public func accessibilityDenyReason(for action: MacInputAction) -> ComputerUseAccessibilityDenyReason? {
        switch inspectDenyRegion(for: action) {
        case .clear:
            return nil
        case .denied(let reason):
            return reason
        case .uninspectable:
            return .unknown
        }
    }

    public func inspectDenyRegion(for action: MacInputAction) -> AccessibilityInspection {
        switch denyRegionTarget(for: action) {
        case .clear:
            return .clear
        case .uninspectable(let detail):
            return .uninspectable(detail)
        case .focus:
            return inspectATSPIDenyRegion(arguments: ["focus"])
        case .points(let points):
            for point in points {
                let result = inspectATSPIDenyRegion(arguments: ["point", String(point.x), String(point.y)])
                if result != .clear {
                    return result
                }
            }
            return .clear
        }
    }

    public func capabilityRows() -> [BurnBarJSONValue] {
        [
            .object([
                "id": .string(AdapterID.atspi2.rawValue),
                "kind": .string("input"),
                "status": .string(atspi2Available() ? "available" : "blocked"),
                "requiresConsent": .bool(true),
                "requiresApproval": .bool(true),
                "reason": .string(atspi2Available() ? "AT-SPI2 bus and python3 are reachable." : "AT-SPI2 bus or python3 is unavailable.")
            ]),
            .object([
                "id": .string(AdapterID.x11XTest.rawValue),
                "kind": .string("input"),
                "status": .string(x11XTestAvailable() ? "available_degraded" : "blocked"),
                "requiresConsent": .bool(false),
                "requiresApproval": .bool(true),
                "reason": .string(x11XTestAvailable() ? "X11 DISPLAY and xdotool are reachable." : "X11 DISPLAY or xdotool is unavailable.")
            ])
        ]
    }

    public func plan(for action: MacInputAction) throws -> DispatchPlan {
        if prefersATSPIClick(for: action), atspi2Available() {
            return try atspi2ClickPlan(for: action)
        }
        if x11XTestAvailable() {
            return try x11XTestPlan(for: action)
        }
        if forcedAdapter() == .atspi2 {
            throw AdapterError.adapterUnavailable("forced at-spi2 but AT-SPI2 bus or python3 is unavailable")
        }
        if forcedAdapter() == .x11XTest {
            throw AdapterError.adapterUnavailable("forced x11-xtest but DISPLAY or xdotool is unavailable")
        }
        throw AdapterError.adapterUnavailable("no approved Linux input adapter is available")
    }

    private func prefersATSPIClick(for action: MacInputAction) -> Bool {
        if let forced = forcedAdapter() {
            return forced == .atspi2
        }
        switch action.kind {
        case .click, .pointerClick:
            return true
        case .type, .key, .shortcut, .dragDrop, .scroll, .pointerMove:
            return false
        }
    }

    private func atspi2ClickPlan(for action: MacInputAction) throws -> DispatchPlan {
        guard action.kind == .click || action.kind == .pointerClick else {
            throw AdapterError.unsupportedAction("AT-SPI2 adapter only supports click and pointer_click")
        }
        guard let python = resolveExecutable("python3") else {
            throw AdapterError.adapterUnavailable("python3 missing")
        }
        guard let x = action.displayX, let y = action.displayY else {
            throw AdapterError.missingCoordinate("AT-SPI2 click requires displayX and displayY")
        }
        return DispatchPlan(
            adapter: .atspi2,
            executablePath: python,
            executableName: "python3",
            arguments: ["-c", Self.atspiClickScript, String(x), String(y)]
        )
    }

    private func x11XTestPlan(for action: MacInputAction) throws -> DispatchPlan {
        guard let xdotool = resolveExecutable("xdotool") else {
            throw AdapterError.adapterUnavailable("xdotool missing")
        }
        let button = xdotoolButton(from: action.mouseButton)
        let arguments: [String]
        switch action.kind {
        case .click, .pointerClick:
            if let x = action.displayX, let y = action.displayY {
                arguments = ["mousemove", String(x), String(y), "click", button]
            } else {
                arguments = ["click", button]
            }
        case .pointerMove:
            arguments = [
                "mousemove_relative",
                "--",
                String(action.deltaX ?? 0),
                String(action.deltaY ?? 0)
            ]
        case .scroll:
            let delta = action.deltaY ?? 0
            let repeatCount = max(1, min(12, abs(delta) / 120 == 0 ? abs(delta) : abs(delta) / 120))
            arguments = ["click", "--repeat", String(repeatCount), delta >= 0 ? "4" : "5"]
        case .dragDrop:
            guard let startX = action.displayX,
                  let startY = action.displayY,
                  let endX = action.dragEndX,
                  let endY = action.dragEndY else {
                throw AdapterError.missingCoordinate("drag_drop requires displayX, displayY, dragEndX, and dragEndY")
            }
            arguments = [
                "mousemove", String(startX), String(startY),
                "mousedown", button,
                "mousemove", String(endX), String(endY),
                "mouseup", button
            ]
        case .type:
            guard let text = action.text, !text.isEmpty else {
                throw AdapterError.unsupportedAction("type requires non-empty text")
            }
            arguments = ["type", "--clearmodifiers", "--delay", "0", text]
        case .key:
            guard let key = action.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdapterError.unsupportedAction("key requires key")
            }
            arguments = ["key", "--clearmodifiers", xdotoolKeyName(key)]
        case .shortcut:
            guard let key = action.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdapterError.unsupportedAction("shortcut requires key")
            }
            let modifiers = (action.modifiers ?? []).map(xdotoolModifierName)
            arguments = ["key", "--clearmodifiers", (modifiers + [xdotoolKeyName(key)]).joined(separator: "+")]
        }
        return DispatchPlan(
            adapter: .x11XTest,
            executablePath: xdotool,
            executableName: "xdotool",
            arguments: arguments
        )
    }

    private func atspi2Available() -> Bool {
        resolveExecutable("python3") != nil
            && (nonEmptyEnvironment("AT_SPI_BUS_ADDRESS") != nil || nonEmptyEnvironment("DBUS_SESSION_BUS_ADDRESS") != nil)
    }

    private func x11XTestAvailable() -> Bool {
        resolveExecutable("xdotool") != nil && nonEmptyEnvironment("DISPLAY") != nil
    }

    private func denyRegionTarget(for action: MacInputAction) -> DenyRegionTarget {
        switch action.kind {
        case .click, .pointerClick:
            guard let x = action.displayX, let y = action.displayY else {
                return .uninspectable("\(action.kind.rawValue) target coordinates unavailable")
            }
            return .points([(x: x, y: y)])
        case .dragDrop:
            guard let startX = action.displayX,
                  let startY = action.displayY,
                  let endX = action.dragEndX,
                  let endY = action.dragEndY else {
                return .uninspectable("drag_drop target coordinates unavailable")
            }
            return .points([(x: startX, y: startY), (x: endX, y: endY)])
        case .scroll:
            guard let x = action.displayX, let y = action.displayY else {
                return .uninspectable("scroll target coordinates unavailable")
            }
            return .points([(x: x, y: y)])
        case .pointerMove:
            guard let x = action.displayX, let y = action.displayY else {
                return .clear
            }
            return .points([(x: x, y: y)])
        case .type, .key, .shortcut:
            return .focus
        }
    }

    private func inspectATSPIDenyRegion(arguments: [String]) -> AccessibilityInspection {
        guard atspi2Available() else {
            return .uninspectable("AT-SPI2 bus or python3 is unavailable")
        }
        guard let python = resolveExecutable("python3") else {
            return .uninspectable("python3 missing")
        }
        let result: CommandResult
        do {
            result = try runCommand(python, ["-c", Self.atspiDenyRegionScript] + arguments)
        } catch {
            return .uninspectable("AT-SPI2 inspection command failed: \(String(describing: error))")
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .uninspectable(detail.isEmpty ? "AT-SPI2 inspection exited \(result.exitCode)" : detail)
        }
        return parseDenyRegionInspection(stdout: result.stdout)
    }

    private func parseDenyRegionInspection(stdout: String) -> AccessibilityInspection {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let inspectable = dict["inspectable"] as? Bool else {
            return .uninspectable("AT-SPI2 inspection returned invalid JSON")
        }
        if !inspectable {
            return .uninspectable(dict["detail"] as? String ?? "AT-SPI2 target was uninspectable")
        }
        if let rawReason = dict["denyReason"] as? String, !rawReason.isEmpty {
            return .denied(ComputerUseAccessibilityDenyReason(rawValue: rawReason) ?? .unknown)
        }
        return .clear
    }

    private func forcedAdapter() -> AdapterID? {
        guard let raw = nonEmptyEnvironment("OPENBURNBAR_LINUX_CU_INPUT_ADAPTER")?.lowercased() else {
            return nil
        }
        switch raw {
        case "at-spi2", "atspi2":
            return .atspi2
        case "x11-xtest", "x11", "xtest", "xdotool":
            return .x11XTest
        default:
            return nil
        }
    }

    private func nonEmptyEnvironment(_ name: String) -> String? {
        guard let value = environment(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func assertKillSwitchNotActive() throws {
        for path in LinuxPrivilegedInputKillFlag.activeFlagPaths(environment: environment) {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw AdapterError.killSwitchActive(path)
            }
        }
    }

    private func xdotoolButton(from mouseButton: Int) -> String {
        switch mouseButton {
        case 1:
            return "3"
        case 2:
            return "2"
        default:
            return "1"
        }
    }

    private func xdotoolKeyName(_ key: String) -> String {
        switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "return", "enter":
            return "Return"
        case "escape", "esc":
            return "Escape"
        case "delete", "backspace":
            return "BackSpace"
        case "tab":
            return "Tab"
        case "space":
            return "space"
        case "arrowleft", "left":
            return "Left"
        case "arrowright", "right":
            return "Right"
        case "arrowup", "up":
            return "Up"
        case "arrowdown", "down":
            return "Down"
        default:
            return key
        }
    }

    private func xdotoolModifierName(_ modifier: String) -> String {
        switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "control", "ctrl":
            return "ctrl"
        case "command", "cmd", "super", "meta":
            return "super"
        case "alternate", "option", "alt":
            return "alt"
        case "shift":
            return "shift"
        default:
            return modifier
        }
    }

    private static func which(_ name: String) -> String? {
        let candidates: [String]
        switch name {
        case "python3":
            candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
        case "xdotool":
            candidates = ["/usr/bin/xdotool", "/usr/local/bin/xdotool"]
        default:
            candidates = []
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: readPipe(output),
            stderr: readPipe(error)
        )
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let atspiClickScript = #"""
import sys
try:
    import pyatspi
except Exception as exc:
    print("pyatspi_unavailable:%s" % exc, file=sys.stderr)
    sys.exit(72)
x = int(sys.argv[1])
y = int(sys.argv[2])
desktop = pyatspi.Registry.getDesktop(0)
visited = set()

def extents(acc):
    try:
        component = acc.queryComponent()
        return component.getExtents(pyatspi.DESKTOP_COORDS)
    except Exception:
        return None

def actions(acc):
    try:
        return acc.queryAction()
    except Exception:
        return None

def walk(acc):
    key = id(acc)
    if key in visited:
        return None
    visited.add(key)
    bounds = extents(acc)
    if bounds and bounds.x <= x < bounds.x + bounds.width and bounds.y <= y < bounds.y + bounds.height:
        action = actions(acc)
        if action and action.nActions > 0:
            if action.doAction(0):
                print("atspi_action:%s" % getattr(acc, "name", ""))
                return True
    try:
        count = acc.childCount
    except Exception:
        count = 0
    for index in range(count):
        try:
            child = acc.getChildAtIndex(index)
        except Exception:
            continue
        result = walk(child)
        if result:
            return result
    return None

if walk(desktop):
    sys.exit(0)
print("no_actionable_accessible_at_coordinate", file=sys.stderr)
sys.exit(73)
"""#

    private static let atspiDenyRegionScript = #"""
import json
import sys

try:
    import pyatspi
except Exception as exc:
    print("pyatspi_unavailable:%s" % exc, file=sys.stderr)
    sys.exit(72)

def emit(inspectable, deny_reason=None, detail=None):
    print(json.dumps({
        "inspectable": inspectable,
        "denyReason": deny_reason,
        "detail": detail
    }))

def text(value):
    try:
        return str(value or "").lower()
    except Exception:
        return ""

def extents(acc):
    try:
        component = acc.queryComponent()
        return component.getExtents(pyatspi.DESKTOP_COORDS)
    except Exception:
        return None

def child_count(acc):
    try:
        return acc.childCount
    except Exception:
        return 0

def child_at(acc, index):
    try:
        return acc.getChildAtIndex(index)
    except Exception:
        return None

def role_value(acc):
    try:
        return int(acc.getRole())
    except Exception:
        return -1

def role_name(acc):
    try:
        return text(acc.getRoleName())
    except Exception:
        return ""

def state_contains(acc, state):
    try:
        return acc.getState().contains(state)
    except Exception:
        return False

def state_names(acc):
    names = []
    for name in dir(pyatspi):
        if not name.startswith("STATE_"):
            continue
        try:
            value = getattr(pyatspi, name)
            if state_contains(acc, value):
                names.append(name.lower())
        except Exception:
            continue
    return names

def target_text(acc):
    values = [
        role_name(acc),
        text(getattr(acc, "name", "")),
        text(getattr(acc, "description", "")),
        " ".join(state_names(acc))
    ]
    return " ".join(values)

def classify(acc):
    role = role_value(acc)
    words = target_text(acc)
    password_role = getattr(pyatspi, "ROLE_PASSWORD_TEXT", None)
    if password_role is not None and role == int(password_role):
        return "secure_text_field"
    if "password" in words or "protected" in words or "secure text" in words:
        return "secure_text_field"
    if any(token in words for token in ["keyring", "gnome-keyring", "kwallet", "seahorse"]):
        return "keychain_prompt"
    auth_tokens = [
        "authenticate",
        "authentication",
        "authorization",
        "authorize",
        "polkit",
        "policykit",
        "lock screen",
        "unlock",
        "login window",
        "system password",
        "sudo"
    ]
    role_tokens = ["alert", "dialog", "sheet", "window", "panel"]
    if any(token in words for token in auth_tokens) and (
        any(token in words for token in role_tokens) or "password" in words
    ):
        return "system_auth_sheet"
    return None

def deepest_at(acc, x, y, visited):
    key = id(acc)
    if key in visited:
        return None
    visited.add(key)
    candidate = None
    bounds = extents(acc)
    if bounds and bounds.x <= x < bounds.x + bounds.width and bounds.y <= y < bounds.y + bounds.height:
        candidate = acc
    for index in range(child_count(acc)):
        child = child_at(acc, index)
        if child is None:
            continue
        nested = deepest_at(child, x, y, visited)
        if nested is not None:
            candidate = nested
    return candidate

def focused(acc, visited):
    key = id(acc)
    if key in visited:
        return None
    visited.add(key)
    if state_contains(acc, pyatspi.STATE_FOCUSED):
        return acc
    for index in range(child_count(acc)):
        child = child_at(acc, index)
        if child is None:
            continue
        nested = focused(child, visited)
        if nested is not None:
            return nested
    return None

try:
    mode = sys.argv[1]
except Exception:
    emit(False, detail="missing inspection mode")
    sys.exit(0)

try:
    desktop = pyatspi.Registry.getDesktop(0)
except Exception as exc:
    emit(False, detail="desktop_unavailable:%s" % exc)
    sys.exit(0)

if mode == "point":
    try:
        x = int(sys.argv[2])
        y = int(sys.argv[3])
    except Exception:
        emit(False, detail="invalid point coordinates")
        sys.exit(0)
    target = deepest_at(desktop, x, y, set())
elif mode == "focus":
    target = focused(desktop, set())
else:
    emit(False, detail="unknown inspection mode")
    sys.exit(0)

if target is None:
    emit(False, detail="no accessible target")
    sys.exit(0)

emit(True, deny_reason=classify(target))
"""#
}
#endif
