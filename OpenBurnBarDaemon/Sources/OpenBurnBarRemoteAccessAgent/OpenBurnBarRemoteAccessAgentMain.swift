import ApplicationServices
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import IOKit.pwr_mgt
import OpenBurnBarRemoteAccessAgentCore
import SystemConfiguration

private let agentVersion = "1"
private let defaultSocketPath = "/var/run/openburnbar-remote-access-agent.sock"
private let maximumRequestBytes = 16 * 1024
private let maximumCredentialUTF8Bytes = 1_024
private let requestIOTimeoutSeconds: time_t = 2
/// Backstop only — the worker self-bounds its own focus+type+retry work well under this. Killing
/// the worker before it finishes typing is what produced `login_session_worker_timed_out`, so this
/// is derived from the shared nesting policy rather than a hand-tuned magic number.
private let credentialWorkerExitTimeoutNanoseconds: UInt64 =
    RemoteAccessCredentialTimeoutPolicy.workerExitTimeoutNanoseconds

private func agentLog(_ message: String) {
    let line = "remote_access_agent \(Date().timeIntervalSince1970): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

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
        signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains("--type-credential-worker") {
            // Surface worker failures in the main log (stdout), not only the .err stderr crash trace,
            // so the loginwindow keystroke path is diagnosable from one place, then exit non-zero so
            // the parent reports the failure instead of a false success.
            do {
                try RemoteAccessCredentialWorker.run()
            } catch {
                let detail = (error as? AgentError)?.rawValue ?? String(describing: error)
                agentLog("credential worker error detail=\(detail)")
                exit(1)
            }
            return
        }

        if CommandLine.arguments.contains("--focus-probe-worker") {
            do {
                try RemoteAccessCredentialWorker.runFocusProbe()
            } catch {
                let detail = (error as? AgentError)?.rawValue ?? String(describing: error)
                agentLog("focus probe worker error detail=\(detail)")
                exit(1)
            }
            return
        }

        let socketPath = argumentValue("--socket") ?? defaultSocketPath
        let server = try RemoteAccessAgentServer(socketPath: socketPath)
        try server.run()
    }
}

private func argumentValue(_ name: String, in args: [String] = CommandLine.arguments) -> String? {
    guard let index = args.firstIndex(of: name),
          args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

private final class RemoteAccessAgentServer {
    private let socketPath: String
    private let socketFD: Int32
    private let peerAuthenticator: PrivilegedPeerAuthenticator

    init(socketPath: String) throws {
        self.socketPath = socketPath
        self.peerAuthenticator = PrivilegedPeerAuthenticator(socketLabel: socketPath)
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
            configureClientTimeouts(client)
            Thread.detachNewThread { [self] in
                handle(client)
                close(client)
            }
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

        guard listen(socketFD, SOMAXCONN) == 0 else {
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

    private func configureClientTimeouts(_ client: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, pointer, timeoutLength)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, pointer, timeoutLength)
        }
    }

    private func handle(_ client: Int32) {
        do {
            try peerAuthenticator.validateUnixSocketPeer(
                socketFD: client,
                consoleUser: resolveConsoleUser()
            )
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
                agentLog("typeCredential request accepted")
                try RemoteAccessCredentialWorker.launch(password: password)
                try write(AgentResponse(ok: true, error: nil), to: client)
            case "focusProbe":
                // Diagnostic only: runs the focus sequence (pointer nudge + escape + backspaces) at
                // the login window without typing a password or pressing Return, so an operator can
                // confirm whether our synthetic events reach loginwindow and reveal the password
                // field. Safe to run while locked — it can never submit a login attempt.
                agentLog("focusProbe request accepted")
                try RemoteAccessCredentialWorker.launchFocusProbe()
                try write(AgentResponse(ok: true, error: nil), to: client)
            case "requestCapabilityToken":
                // WS2: mint domain-tagged capability tokens offline. Stub keeps the socket contract stable.
                try write(
                    AgentResponse(ok: false, error: AgentError.capabilityTokenNotYetAvailable.rawValue),
                    to: client
                )
            default:
                try write(AgentResponse(ok: false, error: "unsupported_operation"), to: client)
            }
        } catch {
            let detail = agentErrorDetail(for: error)
            try? write(AgentResponse(ok: false, error: detail), to: client)
        }
    }

    private func agentErrorDetail(for error: Error) -> String {
        if let agentError = error as? AgentError {
            return agentError.rawValue
        }
        if let authFailure = error as? PrivilegedPeerAuthenticationFailure {
            switch authFailure {
            case .peerIdentityUnavailable: return AgentError.peerIdentityUnavailable.rawValue
            case .consoleUserUnavailable: return AgentError.consoleUserUnavailable.rawValue
            case .peerNotConsoleUser: return AgentError.peerNotConsoleUser.rawValue
            case .auditTokenUnavailable: return AgentError.peerIdentityUnavailable.rawValue
            case .codeSignatureInvalid: return AgentError.peerCodeSignatureInvalid.rawValue
            }
        }
        return "request_failed"
    }

    private func readRequest(from client: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw AgentError.requestTimedOut }
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
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw AgentError.requestTimedOut }
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
        agentLog("credential worker running uid=\(getuid()) euid=\(geteuid()) gid=\(getgid())")
        let passwordData = try credentialData()
        guard passwordData.count <= maximumCredentialUTF8Bytes,
              let password = String(data: passwordData, encoding: .utf8),
              !password.isEmpty else {
            throw AgentError.credentialInvalid
        }
        guard !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentError.credentialInvalid
        }
        try dropPrivilegesToConsoleUserIfNeeded()
        try RemoteAccessTyper.typeCredential(password)
    }

    /// Diagnostic worker: runs only the focus sequence (no password, no Return) so an operator can
    /// confirm whether our synthetic events reach loginwindow and reveal the password field.
    static func runFocusProbe() throws {
        agentLog("focus probe worker running uid=\(getuid()) euid=\(geteuid()) gid=\(getgid())")
        try dropPrivilegesToConsoleUserIfNeeded()
        try RemoteAccessTyper.focusProbe()
    }

    static func launchFocusProbe() throws {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        guard let consoleUser = resolveConsoleUser() else {
            throw AgentError.consoleUserUnavailable
        }
        let wakeLease = RemoteAccessDisplayWake.prepareForCredentialEntry()
        defer { wakeLease.release() }

        let loginPID = loginWindowPID(for: consoleUser.uid)
        agentLog(
            "launch focus probe worker uid=\(consoleUser.uid) loginWindowPID=\(loginPID.map { String($0) } ?? "nil")"
        )
        try runLaunchctl(
            arguments: RemoteAccessCredentialWorkerLaunchPlan.focusProbeArguments(
                executablePath: executablePath,
                consoleUserUID: consoleUser.uid,
                loginWindowPID: loginPID
            )
        )
    }

    static func launch(password: String) throws {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        guard let consoleUser = resolveConsoleUser() else {
            throw AgentError.consoleUserUnavailable
        }
        let wakeLease = RemoteAccessDisplayWake.prepareForCredentialEntry()
        defer { wakeLease.release() }

        guard let passwordData = password.data(using: .utf8) else {
            throw AgentError.credentialInvalid
        }
        let loginPID = loginWindowPID(for: consoleUser.uid)
        agentLog(
            "launch credential worker uid=\(consoleUser.uid) loginWindowPID=\(loginPID.map { String($0) } ?? "nil")"
        )
        try withCredentialFile(passwordData, owner: consoleUser) { credentialFilePath in
            try runLaunchctl(
                arguments: RemoteAccessCredentialWorkerLaunchPlan.launchctlArguments(
                    executablePath: executablePath,
                    consoleUserUID: consoleUser.uid,
                    loginWindowPID: loginPID,
                    credentialFilePath: credentialFilePath
                )
            )
        }
    }

    private static func runLaunchctl(arguments: [String]) throws {
        let executable = "/bin/launchctl"
        var cArguments: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        cArguments.append(nil)
        defer {
            for argument in cArguments {
                free(argument)
            }
        }

        var pid = pid_t()
        let spawnStatus = cArguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executable, nil, nil, buffer.baseAddress, nil)
        }
        guard spawnStatus == 0 else { throw AgentError.workerLaunchFailed }

        let deadline = DispatchTime.now().uptimeNanoseconds + credentialWorkerExitTimeoutNanoseconds
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0 {
                if errno == EINTR { continue }
                throw AgentError.workerFailed
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                killCredentialWorker(pid)
                throw AgentError.workerTimedOut
            }
            usleep(50_000)
        }

        let exitedNormally = (status & 0x7f) == 0
        let exitCode = (status >> 8) & 0xff
        guard exitedNormally, exitCode == 0 else {
            throw AgentError.workerFailed
        }
    }

    private static func killCredentialWorker(_ pid: pid_t) {
        _ = kill(pid, SIGTERM)
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno != EINTR) { return }
            usleep(25_000)
        }
        _ = kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    private static func credentialData() throws -> Data {
        guard let path = argumentValue("--credential-file") else {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        guard path.hasPrefix("/var/run/openburnbar-remote-access-agent.credential.") else {
            throw AgentError.credentialInvalid
        }
        defer { _ = unlink(path) }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw AgentError.credentialFileReadFailed
        }
    }

    private static func dropPrivilegesToConsoleUserIfNeeded() throws {
        guard geteuid() == 0 else {
            agentLog("credential worker already non-root uid=\(getuid()) euid=\(geteuid()) gid=\(getgid())")
            return
        }
        guard let consoleUser = resolveConsoleUser() else {
            throw AgentError.consoleUserUnavailable
        }
        guard setgid(gid_t(consoleUser.gid)) == 0,
              setuid(uid_t(consoleUser.uid)) == 0 else {
            throw AgentError.workerPrivilegeDropFailed
        }
        agentLog("credential worker dropped privileges uid=\(getuid()) euid=\(geteuid()) gid=\(getgid())")
    }

    private static func withCredentialFile(
        _ passwordData: Data,
        owner: RemoteAccessConsoleUser,
        _ body: (String) throws -> Void
    ) throws {
        var template = Array("/var/run/openburnbar-remote-access-agent.credential.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mkstemp(baseAddress)
        }
        guard fd >= 0 else { throw AgentError.credentialFileUnavailable }

        let path = String(cString: template)
        var shouldClose = true
        defer {
            if shouldClose { close(fd) }
            _ = unlink(path)
        }

        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0,
              fchown(fd, uid_t(owner.uid), gid_t(owner.gid)) == 0 else {
            throw AgentError.credentialFileUnavailable
        }

        try passwordData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < passwordData.count {
                let written = Darwin.write(fd, base.advanced(by: offset), passwordData.count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw AgentError.workerInputFailed
                }
                offset += written
            }
        }

        guard close(fd) == 0 else { throw AgentError.workerInputFailed }
        shouldClose = false
        try body(path)
    }

    private static func loginWindowPID(for uid: uid_t) -> Int32? {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return nil }

        var pids = [pid_t](
            repeating: 0,
            count: Int(bytesNeeded) / MemoryLayout<pid_t>.stride
        )
        let bytesWritten = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesWritten > 0 else { return nil }

        let pidCount = min(pids.count, Int(bytesWritten) / MemoryLayout<pid_t>.stride)
        for pid in pids.prefix(pidCount) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = MemoryLayout<proc_bsdinfo>.stride
            let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(infoSize))
            }
            guard infoResult == Int32(infoSize),
                  info.pbi_uid == uid,
                  let path = processPath(pid),
                  path.hasSuffix("/loginwindow.app/Contents/MacOS/loginwindow") else {
                continue
            }
            return pid
        }
        return nil
    }

    private static func processPath(_ pid: pid_t) -> String? {
        // Mirrors PROC_PIDPATHINFO_MAXSIZE from <sys/proc_info.h>, which is
        // a C macro and is not imported into Swift on macOS 26.5.
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
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
        guard let source = CGEventSource(stateID: keyboardEventSourceStateID()) else {
            throw AgentError.eventSourceUnavailable
        }
        source.localEventsSuppressionInterval = 0
        agentLog(
            "credential worker posting keys source=\(RemoteAccessCredentialEventSourcePolicy.keyboardEventSource.rawValue) tap=\(RemoteAccessCredentialEventSourcePolicy.keyboardEventTap.rawValue)"
        )

        let wakeLease = RemoteAccessDisplayWake.prepareForCredentialEntry()
        defer { wakeLease.release() }

        let keystrokes = RemoteAccessKeystrokePlanner.planForANSIUSKeyboard(password)
        let keyCount = keystrokes?.count ?? password.count
        let maxAttempts = max(1, RemoteAccessCredentialTimeoutPolicy.maximumUnlockAttempts)

        for attempt in 1...maxAttempts {
            // A retry must never type onto an already-unlocked desktop. Past the first attempt, only
            // proceed while the screen is still *confirmed* locked.
            if attempt > 1 {
                let locked = isScreenLocked()
                guard locked == true else {
                    agentLog(
                        "credential worker stop attempt=\(attempt) reason=not_confirmed_locked lockState=\(lockStateDescription(locked))"
                    )
                    return
                }
            }

            agentLog(
                "credential worker focus attempt=\(attempt)/\(maxAttempts) preSubmitKeyPresses=\(RemoteAccessCredentialEventSourcePolicy.preCredentialSubmitKeyPresses)"
            )
            try focusCredentialField(source: source)

            agentLog(
                "credential worker typing attempt=\(attempt) keyCount=\(keyCount) plan=\(keystrokes != nil ? "ansi_us" : "unicode")"
            )
            if let keystrokes {
                for keystroke in keystrokes {
                    try post(keystroke, source: source)
                    usleep(RemoteAccessCredentialEventSourcePolicy.interCharacterSettleMicroseconds)
                }
            } else {
                for character in password {
                    try post(character: String(character), source: source)
                    usleep(RemoteAccessCredentialEventSourcePolicy.interCharacterSettleMicroseconds)
                }
            }

            usleep(RemoteAccessCredentialEventSourcePolicy.preReturnSettleMicroseconds)
            try postReturn(source: source)
            agentLog("credential worker submitted attempt=\(attempt)")

            usleep(RemoteAccessCredentialEventSourcePolicy.postSubmitVerifyDelayMicroseconds)
            let locked = isScreenLocked()
            agentLog("credential worker verify attempt=\(attempt) lockState=\(lockStateDescription(locked))")
            switch locked {
            case .some(false):
                agentLog("credential worker complete attempt=\(attempt) result=unlocked")
                return
            case .none:
                // Lock state unreadable: keystrokes were delivered once and we must not blindly
                // retype (the screen may already be unlocked). Report keystrokes delivered.
                agentLog("credential worker complete attempt=\(attempt) result=delivered_lock_state_unknown")
                return
            case .some(true):
                continue // Still locked — try again if attempts remain.
            }
        }

        agentLog("credential worker complete attempts=\(maxAttempts) result=keystrokes_delivered_still_locked")
    }

    /// Diagnostic: run the focus sequence only — no password keystrokes, no Return — and log the
    /// lock state before and after, so an operator can confirm whether our synthetic events reach
    /// the login window and reveal the password field. Never submits a login attempt.
    static func focusProbe() throws {
        guard let source = CGEventSource(stateID: keyboardEventSourceStateID()) else {
            throw AgentError.eventSourceUnavailable
        }
        source.localEventsSuppressionInterval = 0
        let before = isScreenLocked()
        agentLog(
            "focus probe begin lockState=\(lockStateDescription(before)) source=\(RemoteAccessCredentialEventSourcePolicy.keyboardEventSource.rawValue) tap=\(RemoteAccessCredentialEventSourcePolicy.keyboardEventTap.rawValue)"
        )

        let wakeLease = RemoteAccessDisplayWake.prepareForCredentialEntry()
        defer { wakeLease.release() }

        try focusCredentialField(source: source)

        let after = isScreenLocked()
        agentLog("focus probe complete lockState=\(lockStateDescription(after))")
    }

    private static func focusCredentialField(source: CGEventSource) throws {
        // 1. Wake the lock UI with a pointer move (never a click — a mis-aimed click can collapse the
        //    password lane). Combined with the IOPM user-activity assertion, this reveals the
        //    "enter password" field on Touch-ID-first lock screens.
        try nudgePointer(source: source, normalizedPoint: RemoteAccessCredentialEventSourcePolicy.pointerNudgePoint)
        usleep(RemoteAccessCredentialEventSourcePolicy.pointerNudgeSettleMicroseconds)
        agentLog("credential worker focus step=pointer_nudge done")

        // 2. Escape dismisses the transient "Touch ID or enter password" affordance and drops focus
        //    onto the password lane.
        try postVirtualKey(53, source: source)
        usleep(RemoteAccessCredentialEventSourcePolicy.escapeSettleMicroseconds)
        agentLog("credential worker focus step=escape done")

        // 3. Backspaces focus/clear the password lane. A Backspace on an empty field is a no-op and
        //    never submits, so this is safe even when focus is already correct or stray characters
        //    remain from a prior partial attempt.
        for _ in 0..<RemoteAccessCredentialEventSourcePolicy.focusClearKeyPresses {
            try postVirtualKey(51, source: source)
            usleep(RemoteAccessCredentialEventSourcePolicy.focusKeySettleMicroseconds)
        }
        agentLog(
            "credential worker focus step=clear backspaces=\(RemoteAccessCredentialEventSourcePolicy.focusClearKeyPresses) done"
        )

        usleep(RemoteAccessCredentialEventSourcePolicy.preTypeSettleMicroseconds)
    }

    /// Post a single pointer *move* to wake the lock UI without activating any control.
    private static func nudgePointer(
        source: CGEventSource,
        normalizedPoint: RemoteAccessNormalizedPoint
    ) throws {
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(
            x: displayBounds.minX + displayBounds.width * normalizedPoint.x,
            y: displayBounds.minY + displayBounds.height * normalizedPoint.y
        )
        guard let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw AgentError.eventCreationFailed
        }
        move.post(tap: keyboardEventTap())
    }

    /// Whether the GUI session's screen is locked. `nil` when the lock flag cannot be read, in which
    /// case the worker conservatively stops retrying rather than risk typing onto an unlocked desktop.
    private static func isScreenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber { return locked.boolValue }
        return nil
    }

    private static func lockStateDescription(_ locked: Bool?) -> String {
        switch locked {
        case .some(true): return "locked"
        case .some(false): return "unlocked"
        case .none: return "unknown"
        }
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
        let tap = keyboardEventTap()
        down.post(tap: tap)
        up.post(tap: tap)
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
        let tap = keyboardEventTap()
        down.post(tap: tap)
        up.post(tap: tap)
    }

    private static func postReturn(source: CGEventSource) throws {
        try postVirtualKey(36, source: source)
    }

    private static func keyboardEventSourceStateID() -> CGEventSourceStateID {
        switch RemoteAccessCredentialEventSourcePolicy.keyboardEventSource {
        case .combinedSessionState:
            return .combinedSessionState
        }
    }

    private static func keyboardEventTap() -> CGEventTapLocation {
        switch RemoteAccessCredentialEventSourcePolicy.keyboardEventTap {
        case .sessionEventTap:
            return .cgSessionEventTap
        }
    }
}

private enum AgentError: String, Error {
    case capabilityTokenNotYetAvailable = "capability_token_not_yet_available"
    case consoleUserUnavailable = "console_user_unavailable"
    case credentialInvalid = "credential_invalid"
    case credentialMissing = "credential_missing"
    case credentialTooLarge = "credential_too_large"
    case emptyRequest = "empty_request"
    case eventCreationFailed = "event_creation_failed"
    case eventSourceUnavailable = "event_source_unavailable"
    case peerIdentityUnavailable = "peer_identity_unavailable"
    case peerNotConsoleUser = "peer_not_console_user"
    case peerCodeSignatureInvalid = "peer_code_signature_invalid"
    case requestTooLarge = "request_too_large"
    case requestTimedOut = "request_timed_out"
    case socketPathTooLong = "socket_path_too_long"
    case credentialFileReadFailed = "credential_file_read_failed"
    case credentialFileUnavailable = "credential_file_unavailable"
    case workerFailed = "login_session_worker_failed"
    case workerInputFailed = "login_session_worker_input_failed"
    case workerLaunchFailed = "login_session_worker_launch_failed"
    case workerPrivilegeDropFailed = "login_session_worker_privilege_drop_failed"
    case workerTimedOut = "login_session_worker_timed_out"
}
