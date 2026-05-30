import Foundation
import OpenBurnBarComputerUseCore

/// LaunchDaemon-friendly watchdog that sets `PrivilegedInputKillSwitch` when the Mac app
/// cannot (crash, wedged coordinator). Listens on a root-owned UNIX socket for activate/clear.
enum PrivilegedInputKillSwitchWatchdog {
    static let defaultSocketPath = "/var/run/openburnbar-killswitch-watch.sock"

    struct Command: Decodable {
        let action: String
        let reason: String?
    }

    static func run(socketPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else {
            throw WatchdogError.socketCreateFailed(errno)
        }
        defer { close(server) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw WatchdogError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (index, byte) in pathBytes.enumerated() {
                    dest[index] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(server, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw WatchdogError.bindFailed(errno)
        }

        chmod(socketPath, 0o600)
        guard listen(server, 8) == 0 else {
            throw WatchdogError.listenFailed(errno)
        }

        fputs("openburnbar-killswitch-watchdog listening on \(socketPath)\n", stderr)

        while true {
            var clientAddr = sockaddr()
            var clientLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(server, &clientAddr, &clientLen)
            if client < 0 {
                if errno == EINTR { continue }
                fputs("accept failed errno=\(errno)\n", stderr)
                continue
            }
            handleClient(client)
            close(client)
        }
    }

    private static func handleClient(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let data = Data(buffer.prefix(count))
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            writeResponse(client, ok: false, detail: "malformed_command")
            return
        }
        switch command.action {
        case "activate":
            PrivilegedInputKillSwitch.activate(reason: command.reason ?? "watchdog")
            writeResponse(client, ok: true, detail: "activated")
        case "clear":
            PrivilegedInputKillSwitch.clear()
            writeResponse(client, ok: true, detail: "cleared")
        case "health":
            writeResponse(client, ok: true, detail: PrivilegedInputKillSwitch.isActive ? "active" : "idle")
        default:
            writeResponse(client, ok: false, detail: "unsupported_action")
        }
    }

    private static func writeResponse(_ client: Int32, ok: Bool, detail: String) {
        let payload = Data("{\"ok\":\(ok),\"detail\":\"\(detail)\"}\n".utf8)
        _ = payload.withUnsafeBytes { raw in
            write(client, raw.baseAddress, raw.count)
        }
    }

    enum WatchdogError: Error {
        case socketCreateFailed(Int32)
        case pathTooLong
        case bindFailed(Int32)
        case listenFailed(Int32)
    }
}

@main
struct PrivilegedInputKillSwitchWatchdogMain {
    static func main() {
        let args = CommandLine.arguments
        var socketPath = PrivilegedInputKillSwitchWatchdog.defaultSocketPath
        if let index = args.firstIndex(of: "--socket"), index + 1 < args.count {
            socketPath = args[index + 1]
        }
        do {
            try PrivilegedInputKillSwitchWatchdog.run(socketPath: socketPath)
        } catch {
            fputs("watchdog failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
