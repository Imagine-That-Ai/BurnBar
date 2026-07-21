#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Darwin
import Foundation

private enum HelperError: Error, CustomStringConvertible {
    case usage
    case invalidPID(String)
    case processNotRunning(pid_t)
    case timeout(String)
    case processInfoUnavailable(pid_t)
    case invalidCPUTimestamp
    case backdropStateTimeout(pid_t, Bool)

    var description: String {
        switch self {
        case .usage:
            return "usage: macos-idle-occlusion-gate-helper <status|show|hide|wait-visible|wait-hidden|cpu> <pid> [timeout-ms]"
        case .invalidPID(let value):
            return "invalid pid: \(value)"
        case .processNotRunning(let pid):
            return "process is not running: \(pid)"
        case .timeout(let message):
            return message
        case .processInfoUnavailable(let pid):
            return "proc_pidinfo failed for pid \(pid)"
        case .invalidCPUTimestamp:
            return "failed to convert proc_pidinfo CPU time to nanoseconds"
        case .backdropStateTimeout(let pid, let visible):
            return "timed out waiting for pid \(pid) backdrop state visible=\(visible)"
        }
    }
}

private struct WindowState: Codable {
    let pid: Int32
    let running: Bool
    let hidden: Bool
    let active: Bool
    let activationPolicy: Int
    let visibleWindowCount: Int
    let executablePath: String?
    let bundleIdentifier: String?
    let backdropReady: Bool?
    let backdropActive: Bool?
    let backdropRenderLoopScheduled: Bool?
    let backdropReducedMotion: Bool?
    let backdropKernel: String?
}

private struct BackdropState {
    let ready: Bool
    let active: Bool
    let renderLoopScheduled: Bool
    let reducedMotion: Bool
    let kernel: String
}

private struct CPUSnapshot: Codable {
    let pid: Int32
    let monotonicNanoseconds: String
    let cpuNanoseconds: String
}
private let performanceGateVisibilityNotification = Notification.Name(
    "com.openburnbar.performance-gate.window-visibility"
)
private let performanceGateBackdropStateNotification = Notification.Name(
    "com.openburnbar.performance-gate.backdrop-state"
)

private func requestWindowVisibility(pid: pid_t, visible: Bool) {
    DistributedNotificationCenter.default().postNotificationName(
        performanceGateVisibilityNotification,
        object: String(pid),
        userInfo: ["visible": visible],
        deliverImmediately: true
    )
}

private func waitForBackdropState(
    pid: pid_t,
    visible: Bool,
    timeoutMilliseconds: Int
) throws -> BackdropState {
    let center = DistributedNotificationCenter.default()
    var received: BackdropState?
    let observer = center.addObserver(
        forName: performanceGateBackdropStateNotification,
        object: String(pid),
        queue: .main
    ) { notification in
        guard let userInfo = notification.userInfo,
              userInfo["ready"] as? Bool == true,
              let active = userInfo["hostVisible"] as? Bool,
              let renderLoopScheduled = userInfo["renderLoopScheduled"] as? Bool,
              let reducedMotion = userInfo["reducedMotion"] as? Bool,
              let kernel = userInfo["kernel"] as? String
        else { return }
        received = BackdropState(
            ready: true,
            active: active,
            renderLoopScheduled: renderLoopScheduled,
            reducedMotion: reducedMotion,
            kernel: kernel
        )
    }
    defer { center.removeObserver(observer) }

    let deadline = DispatchTime.now().uptimeNanoseconds
        + UInt64(timeoutMilliseconds) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        requestWindowVisibility(pid: pid, visible: visible)
        let responseDeadline = Date().addingTimeInterval(0.1)
        repeat {
            _ = RunLoop.current.run(mode: .default, before: responseDeadline)
            if let state = received,
               state.active == visible,
               state.ready,
               state.kernel == "fluid-aurora",
               !state.reducedMotion,
               state.renderLoopScheduled == visible {
                return state
            }
        } while Date() < responseDeadline
    }
    throw HelperError.backdropStateTimeout(pid, visible)
}

private func visibleWindowCount(for pid: pid_t) -> Int {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return 0
    }

    return rows.reduce(into: 0) { count, row in
        guard let ownerPID = row[kCGWindowOwnerPID as String] as? NSNumber,
              ownerPID.int32Value == pid,
              let layer = row[kCGWindowLayer as String] as? NSNumber,
              layer.intValue == 0,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber,
              width.doubleValue >= 100,
              height.doubleValue >= 100 else { return }
        count += 1
    }
}

private func state(for pid: pid_t, backdrop: BackdropState? = nil) throws -> WindowState {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw HelperError.processNotRunning(pid)
    }
    return WindowState(
        pid: pid,
        running: !app.isTerminated,
        hidden: app.isHidden,
        active: app.isActive,
        activationPolicy: app.activationPolicy.rawValue,
        visibleWindowCount: visibleWindowCount(for: pid),
        executablePath: app.executableURL?.resolvingSymlinksInPath().path,
        bundleIdentifier: app.bundleIdentifier,
        backdropReady: backdrop?.ready,
        backdropActive: backdrop?.active,
        backdropRenderLoopScheduled: backdrop?.renderLoopScheduled,
        backdropReducedMotion: backdrop?.reducedMotion,
        backdropKernel: backdrop?.kernel
    )
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func waitForState(
    pid: pid_t,
    timeoutMilliseconds: Int,
    description: String,
    predicate: (WindowState) -> Bool
) throws -> WindowState {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while true {
        let current = try state(for: pid)
        if predicate(current) { return current }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            throw HelperError.timeout(
                "timed out waiting for \(description) for pid \(pid); "
                    + "hidden=\(current.hidden), active=\(current.active), "
                    + "visibleWindowCount=\(current.visibleWindowCount)"
            )
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

private func absoluteTimeNanoseconds(_ ticks: UInt64) throws -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS,
          timebase.numer > 0,
          timebase.denom > 0 else {
        throw HelperError.invalidCPUTimestamp
    }

    let numerator = UInt64(timebase.numer)
    guard ticks <= UInt64.max / numerator else {
        throw HelperError.invalidCPUTimestamp
    }
    return ticks * numerator / UInt64(timebase.denom)
}

private func cpuSnapshot(for pid: pid_t) throws -> CPUSnapshot {
    var taskInfo = proc_taskinfo()
    let expectedSize = MemoryLayout<proc_taskinfo>.stride
    let actualSize = withUnsafeMutablePointer(to: &taskInfo) { pointer in
        proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, Int32(expectedSize))
    }
    guard actualSize == Int32(expectedSize) else {
        throw HelperError.processInfoUnavailable(pid)
    }
    let (cpuTicks, overflow) = taskInfo.pti_total_user.addingReportingOverflow(taskInfo.pti_total_system)
    guard !overflow else { throw HelperError.invalidCPUTimestamp }
    return CPUSnapshot(
        pid: pid,
        monotonicNanoseconds: String(DispatchTime.now().uptimeNanoseconds),
        cpuNanoseconds: String(try absoluteTimeNanoseconds(cpuTicks))
    )
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { throw HelperError.usage }
    let command = arguments[0]
    guard let pid = pid_t(arguments[1]), pid > 0 else {
        throw HelperError.invalidPID(arguments[1])
    }
    let timeoutMilliseconds: Int
    if arguments.count >= 3 {
        guard let parsed = Int(arguments[2]), parsed > 0 else { throw HelperError.usage }
        timeoutMilliseconds = parsed
    } else {
        timeoutMilliseconds = 15_000
    }

    switch command {
    case "status":
        try emit(state(for: pid))
    case "show":
        _ = try state(for: pid)
        let backdrop = try waitForBackdropState(
            pid: pid,
            visible: true,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let visible = try waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "a visible application window"
        ) { $0.visibleWindowCount > 0 }
        try emit(try state(for: visible.pid, backdrop: backdrop))
    case "hide":
        _ = try state(for: pid)
        let backdrop = try waitForBackdropState(
            pid: pid,
            visible: false,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let hidden = try waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "a fully occluded application window"
        ) { $0.visibleWindowCount == 0 }
        try emit(try state(for: hidden.pid, backdrop: backdrop))
    case "wait-visible":
        let backdrop = try waitForBackdropState(
            pid: pid,
            visible: true,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let visible = try waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "a visible application window"
        ) { $0.visibleWindowCount > 0 }
        try emit(try state(for: visible.pid, backdrop: backdrop))
    case "wait-hidden":
        let backdrop = try waitForBackdropState(
            pid: pid,
            visible: false,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let hidden = try waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "a fully occluded application window"
        ) { $0.visibleWindowCount == 0 }
        try emit(try state(for: hidden.pid, backdrop: backdrop))
    case "cpu":
        try emit(cpuSnapshot(for: pid))
    default:
        throw HelperError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}
