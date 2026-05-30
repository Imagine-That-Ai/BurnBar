import Darwin
import Foundation
import OpenBurnBarRemoteAccessAgentCore

/// Red-team probe: connect to a privileged OpenBurnBar socket as an unsigned console-user process
/// and attempt a forbidden `"input"` dispatch. Exit 0 if the server accepts (vulnerable), 1 if rejected (expected after P0).
@main
struct OpenBurnBarPrivilegedSocketRedTeamProbe {
    static func main() {
        let socketPath = CommandLine.arguments.dropFirst().first
            ?? "/var/run/openburnbar-virtual-hid.sock"
        let operation = CommandLine.arguments.dropFirst().dropFirst().first ?? "input"

        do {
            let rejected = try probe(socketPath: socketPath, operation: operation)
            exit(rejected ? 1 : 0)
        } catch {
            fputs("probe_error \(error)\n", stderr)
            exit(2)
        }
    }

    private static func probe(socketPath: String, operation: String) throws -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeError.socketUnavailable }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw ProbeError.pathTooLong }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ProbeError.connectFailed }

        let payload: [String: Any]
        if operation == "input" {
            payload = [
                "operation": "input",
                "kind": "type",
                "text": "pwned-by-red-team"
            ]
        } else {
            payload = ["operation": operation]
        }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count >= 0 else { throw ProbeError.writeFailed }
                written += count
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseData = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw ProbeError.readFailed }
            responseData.append(buffer, count: count)
            if responseData.last == 0x0A { break }
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return true
        }
        let ok = json["ok"] as? Bool ?? false
        return !ok
    }

    private enum ProbeError: Error {
        case connectFailed
        case pathTooLong
        case readFailed
        case socketUnavailable
        case writeFailed
    }
}
