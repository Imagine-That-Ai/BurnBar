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
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
}
#endif
