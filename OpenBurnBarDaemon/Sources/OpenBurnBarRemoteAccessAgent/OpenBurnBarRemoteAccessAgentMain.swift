import ApplicationServices
import Darwin
import Foundation
import IOKit.pwr_mgt
import OpenBurnBarRemoteAccessAgentCore
import SystemConfiguration

private let agentVersion = "1"
private let defaultSocketPath = "/var/run/openburnbar-remote-access-agent.sock"
private let maximumRequestBytes = 16 * 1024
private let maximumCredentialUTF8Bytes = 1_024

private struct AgentRequest: Decodable {
    var operation: String
    var password: String?
}

private struct AgentResponse: Encodable {
    var ok: Bool
    var version: String = agentVersion
    var error: String?
}

@main
struct OpenBurnBarRemoteAccessAgentMain {
    static func main() throws {
        if CommandLine.arguments.contains("--type-credential-worker") {
            try RemoteAccessCredentialWorker.run()
            return
        }

        let socketPath = argumentValue("--socket") ?? defaultSocketPath
        let server = try RemoteAccessAgentServer(socketPath: socketPath)
        try server.run()
    }

    private static func argumentValue(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name),
              args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}

private final class RemoteAccessAgentServer {
    private let socketPath: String
    private let socketFD: Int32

    init(socketPath: String) throws {
        self.socketPath = socketPath
        self.socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try bindSocket()
    }

    deinit {
        close(socketFD)
        unlink(socketPath)
    }

    func run() throws -> Never {
        // The socket is owned by `root` but must be reachable by the logged-in GUI user. The
        // console user can change at any time (login, lock, fast-user-switch), so we re-assert
        // ownership on a short cadence instead of only after each accepted connection — otherwise
        // a connection that never arrives (e.g. the daemon started before anyone logged in) would
        // leave the socket permanently unreachable. `poll` gives us that periodic wake-up without
        // a busy loop, and crucially keeps the daemon alive across states where no console user is
        // present (the login window), where the old "refresh-or-die" loop crash-looped under
        // launchd and made Remote Unlock unreachable exactly when it was needed.
        while true {
            refreshSocketOwner()

            var descriptor = pollfd(fd: socketFD, events: Int16(truncatingIfNeeded: POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1_000)
            if ready < 0 {
                if errno == EINTR { continue }
                // A genuine poll failure on a valid fd is not expected; pause briefly to avoid a
                // tight spin, then retry rather than tear down the only unlock path.
                usleep(100_000)
                continue
            }
            guard ready > 0,
                  descriptor.revents & Int16(truncatingIfNeeded: POLLIN) != 0 else {
                continue
            }

            let client = accept(socketFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                // Transient accept errors (e.g. the peer hung up) must not kill the server.
                continue
            }
            handle(client)
            close(client)
        }
    }

    private func bindSocket() throws {
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw AgentError.socketPathTooLong }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        // Best-effort: if no user is logged in yet (boot before login) we still bind and listen,
        // then keep re-asserting ownership from the run loop once a user appears.
        refreshSocketOwner()

        guard listen(socketFD, 16) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// Re-assert socket ownership so the logged-in GUI user can connect while everyone else is
    /// kept out by file permissions (peer credentials are still verified in `validatePeer`).
    ///
    /// Best-effort by design: when no interactive user is present (login window) we leave the
    /// socket owned by `root` rather than failing. This must never throw — a transient inability
    /// to resolve the console user previously crashed the daemon under launchd.
    private func refreshSocketOwner() {
        let owner = resolveConsoleUser()
        let uid: uid_t = owner?.uid ?? 0
        let gid: gid_t = owner?.gid ?? 0
        _ = chown(socketPath, uid, gid)
        _ = chmod(socketPath, S_IRUSR | S_IWUSR)
    }

    private func handle(_ client: Int32) {
        do {
            try validatePeer(client)
            let requestData = try readRequest(from: client)
            let request = try JSONDecoder().decode(AgentRequest.self, from: requestData)
            switch request.operation {
            case "health":
                try write(AgentResponse(ok: true, error: nil), to: client)
            case "wakeDisplay":
                let lease = RemoteAccessDisplayWake.prepareForCredentialEntry()
                lease.release()
                try write(AgentResponse(ok: true, error: nil), to: client)
            case "typeCredential":
                let password = try validatedPassword(request.password)
                try RemoteAccessCredentialWorker.launch(password: password)
                try write(AgentResponse(ok: true, error: nil), to: client)
            default:
                try write(AgentResponse(ok: false, error: "unsupported_operation"), to: client)
            }
        } catch {
            let detail = (error as? AgentError)?.rawValue ?? "request_failed"
            try? write(AgentResponse(ok: false, error: detail), to: client)
        }
    }

    private func validatePeer(_ client: Int32) throws {
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(client, &peerUID, &peerGID) == 0 else {
            throw AgentError.peerIdentityUnavailable
        }
        guard let consoleUser = resolveConsoleUser() else {
            throw AgentError.consoleUserUnavailable
        }
        guard peerUID == consoleUser.uid else {
            throw AgentError.peerNotConsoleUser
        }
    }

    private func readRequest(from client: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
            if data.count > maximumRequestBytes { throw AgentError.requestTooLarge }
            if data.last == 0x0A { break }
        }
        guard !data.isEmpty else { throw AgentError.emptyRequest }
        return data
    }

    private func write(_ response: AgentResponse, to client: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(client, base.advanced(by: offset), data.count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    private func validatedPassword(_ candidate: String?) throws -> String {
        guard let candidate, !candidate.isEmpty else { throw AgentError.credentialMissing }
        guard candidate.utf8.count <= maximumCredentialUTF8Bytes else { throw AgentError.credentialTooLarge }
        guard !candidate.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentError.credentialInvalid
        }
        return candidate
    }
}

/// Resolve the logged-in GUI user, preferring the canonical console user from SystemConfiguration
/// (which survives a screen lock) and falling back to the `/dev/console` device owner. Returns
/// `nil` when only the login window / root is present, so callers can keep the daemon alive.
private func resolveConsoleUser() -> RemoteAccessConsoleUser? {
    RemoteAccessConsoleUserResolver.resolve(
        dynamicStoreUser: consoleUserFromDynamicStore(),
        consoleDeviceOwner: consoleDeviceOwner()
    )
}

/// The current console user as reported by `SCDynamicStoreCopyConsoleUser`. This continues to
/// report the logged-in account (e.g. uid 501) while the screen is locked — it only reports
/// `"loginwindow"`/uid 0 once the user has logged out or switched to the login window.
private func consoleUserFromDynamicStore() -> (name: String?, uid: UInt32, gid: UInt32)? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else {
        return nil
    }
    return (name: name as String, uid: uid, gid: gid)
}

/// The owner of `/dev/console`. Used only as a fallback: it flips to `root` when the screen is
/// locked, so it must never override a real console user from SystemConfiguration.
private func consoleDeviceOwner() -> (uid: UInt32, gid: UInt32)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
          let uid = attributes[.ownerAccountID] as? NSNumber,
          let gid = attributes[.groupOwnerAccountID] as? NSNumber else {
        return nil
    }
    return (uid: uid.uint32Value, gid: gid.uint32Value)
}

private enum RemoteAccessCredentialWorker {
    static func run() throws {
        let passwordData = FileHandle.standardInput.readDataToEndOfFile()
        guard passwordData.count <= maximumCredentialUTF8Bytes,
              let password = String(data: passwordData, encoding: .utf8),
              !password.isEmpty else {
            throw AgentError.credentialInvalid
        }
        guard !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentError.credentialInvalid
        }
        try RemoteAccessTyper.typeCredential(password)
    }

    static func launch(password: String) throws {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        guard let consoleUser = resolveConsoleUser() else {
            throw AgentError.consoleUserUnavailable
        }
        let wakeLease = RemoteAccessDisplayWake.prepareForCredentialEntry()
        defer { wakeLease.release() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        if let loginWindowPID = loginWindowPID(for: consoleUser.uid) {
            process.arguments = [
                "bsexec",
                "\(loginWindowPID)",
                executablePath,
                "--type-credential-worker"
            ]
        } else {
            process.arguments = [
                "asuser",
                "\(consoleUser.uid)",
                executablePath,
                "--type-credential-worker"
            ]
        }

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw AgentError.workerLaunchFailed
        }

        guard let passwordData = password.data(using: .utf8) else {
            throw AgentError.credentialInvalid
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: passwordData)
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw AgentError.workerInputFailed
        }

        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw AgentError.workerFailed
        }
    }

    private static func loginWindowPID(for uid: uid_t) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let processUID = UInt32(fields[1]),
                  processUID == uid,
                  fields[2].hasSuffix("/loginwindow.app/Contents/MacOS/loginwindow") else {
                continue
            }
            return pid
        }
        return nil
    }
}

private struct RemoteAccessDisplayWakeLease {
    var assertionID: IOPMAssertionID?
    var displayWasAsleep: Bool

    func release() {
        guard let assertionID, assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
    }
}

private enum RemoteAccessDisplayWake {
    static func prepareForCredentialEntry() -> RemoteAccessDisplayWakeLease {
        let displayWasAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

        var userActivityAssertion = IOPMAssertionID(0)
        if IOPMAssertionDeclareUserActivity(
            "OpenBurnBar Remote Unlock" as CFString,
            kIOPMUserActiveRemote,
            &userActivityAssertion
        ) == kIOReturnSuccess, userActivityAssertion != 0 {
            IOPMAssertionRelease(userActivityAssertion)
        }

        var noDisplaySleepAssertion = IOPMAssertionID(0)
        let noDisplaySleepResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "OpenBurnBar Remote Unlock credential entry" as CFString,
            &noDisplaySleepAssertion
        )
        let lease = RemoteAccessDisplayWakeLease(
            assertionID: noDisplaySleepResult == kIOReturnSuccess ? noDisplaySleepAssertion : nil,
            displayWasAsleep: displayWasAsleep
        )

        usleep(RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: displayWasAsleep))
        return lease
    }
}

private enum RemoteAccessTyper {
    static func typeCredential(_ password: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AgentError.eventSourceUnavailable
        }
        source.localEventsSuppressionInterval = 0

        let wakeLease = RemoteAccessDisplayWake.prepareForCredentialEntry()
        defer { wakeLease.release() }

        try focusCredentialField(source: source)
        if let plan = RemoteAccessKeystrokePlanner.planForANSIUSKeyboard(password) {
            for keystroke in plan {
                try post(keystroke, source: source)
                usleep(18_000)
            }
        } else {
            for character in password {
                try post(character: String(character), source: source)
                usleep(18_000)
            }
        }
        try postReturn(source: source)
    }

    private static func focusCredentialField(source: CGEventSource) throws {
        try postVirtualKey(36, source: source)
        usleep(180_000)
    }

    private static func post(_ keystroke: RemoteAccessKeystroke, source: CGEventSource) throws {
        let flags: CGEventFlags = keystroke.requiresShift ? .maskShift : []
        try postVirtualKey(CGKeyCode(keystroke.virtualKey), flags: flags, source: source)
    }

    private static func postVirtualKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        source: CGEventSource
    ) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw AgentError.eventCreationFailed
        }
        if !flags.isEmpty {
            down.flags = down.flags.union(flags)
            up.flags = up.flags.union(flags)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func post(character: String, source: CGEventSource) throws {
        var utf16 = Array(character.utf16)
        guard !utf16.isEmpty else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw AgentError.eventCreationFailed
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postReturn(source: CGEventSource) throws {
        try postVirtualKey(36, source: source)
    }
}

private enum AgentError: String, Error {
    case consoleUserUnavailable = "console_user_unavailable"
    case credentialInvalid = "credential_invalid"
    case credentialMissing = "credential_missing"
    case credentialTooLarge = "credential_too_large"
    case emptyRequest = "empty_request"
    case eventCreationFailed = "event_creation_failed"
    case eventSourceUnavailable = "event_source_unavailable"
    case peerIdentityUnavailable = "peer_identity_unavailable"
    case peerNotConsoleUser = "peer_not_console_user"
    case requestTooLarge = "request_too_large"
    case socketPathTooLong = "socket_path_too_long"
    case workerFailed = "login_session_worker_failed"
    case workerInputFailed = "login_session_worker_input_failed"
    case workerLaunchFailed = "login_session_worker_launch_failed"
}
