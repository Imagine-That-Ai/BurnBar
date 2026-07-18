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
        }
    }
}

private struct WindowState: Codable {
    let pid: Int32
    let running: Bool
    let hidden: Bool
    let active: Bool
    let visibleWindowCount: Int
    let executablePath: String?
    let bundleIdentifier: String?
}

private struct CPUSnapshot: Codable {
    let pid: Int32
    let monotonicNanoseconds: String
    let cpuNanoseconds: String
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

private func state(for pid: pid_t) throws -> WindowState {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw HelperError.processNotRunning(pid)
    }
    return WindowState(
        pid: pid,
        running: !app.isTerminated,
        hidden: app.isHidden,
        active: app.isActive,
        visibleWindowCount: visibleWindowCount(for: pid),
        executablePath: app.executableURL?.resolvingSymlinksInPath().path,
        bundleIdentifier: app.bundleIdentifier
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
            throw HelperError.timeout("timed out waiting for \(description) for pid \(pid)")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
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
    return CPUSnapshot(
        pid: pid,
        monotonicNanoseconds: String(DispatchTime.now().uptimeNanoseconds),
        cpuNanoseconds: String(taskInfo.pti_total_user + taskInfo.pti_total_system)
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
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw HelperError.processNotRunning(pid)
        }
        _ = app.unhide()
        _ = app.activate(options: [])
        let visible = try waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "a visible application window"
        ) { !$0.hidden && $0.visibleWindowCount > 0 }
        try emit(visible)
    case "hide":
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw HelperError.processNotRunning(pid)
        }
        _ = app.hide()
        let hidden = try waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "an app-hidden, fully occluded window"
        ) { $0.hidden && $0.visibleWindowCount == 0 }
        try emit(hidden)
    case "wait-visible":
        try emit(waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "a visible application window"
        ) { !$0.hidden && $0.visibleWindowCount > 0 })
    case "wait-hidden":
        try emit(waitForState(
            pid: pid,
            timeoutMilliseconds: timeoutMilliseconds,
            description: "an app-hidden, fully occluded window"
        ) { $0.hidden && $0.visibleWindowCount == 0 })
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
