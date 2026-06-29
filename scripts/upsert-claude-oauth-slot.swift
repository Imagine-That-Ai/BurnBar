#!/usr/bin/env swift
import Foundation

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif

// Minimal inline RPC client for one-off operator repair scripts.
struct UpsertRequest: Codable {
    let id: String
    let method: String
    let authToken: String?
    let params: UpsertParams
}

struct UpsertParams: Codable {
    let providerID: String
    let slotID: String?
    let label: String
    let apiKey: String
    let isEnabled: Bool
    let endpointProfileID: String?
    let region: String?
    let tokenPlanTier: String?
    let tokenPlanBillingCycle: String?
    let authMethodID: String?
}

struct RPCError: Codable { let code: Int; let message: String }
struct RPCEnvelope<T: Codable>: Codable {
    let id: String
    let result: T?
    let error: RPCError?
}

struct SlotMutationResponse: Codable {
    let slot: Slot
    struct Slot: Codable { let slotID: String }
}

func trimmedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

func readClaudeCodeKeychainPayload(account: String) -> String? {
    #if os(macOS)
    let securityURL = URL(fileURLWithPath: "/usr/bin/security")
    guard FileManager.default.isExecutableFile(atPath: securityURL.path),
          !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    let process = Process()
    process.executableURL = securityURL
    process.arguments = [
        "find-generic-password",
        "-w",
        "-s", "Claude Code-credentials",
        "-a", account
    ]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    let errorSink = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = errorSink
    defer {
        try? errorSink?.close()
    }

    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return trimmedNonEmpty(String(data: data, encoding: .utf8))
    #else
    return nil
    #endif
}

func normalizedClaudeOAuthStoragePayload(from raw: String) throws -> String? {
    guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
    guard trimmedNonEmpty(oauth["accessToken"] as? String) != nil else {
        return nil
    }
    guard !claudeOAuthPayloadIsExpired(oauth["expiresAt"]) else {
        return nil
    }

    var payload: [String: Any] = ["claudeAiOauth": oauth]
    if let organizationUuid = trimmedNonEmpty((root["organizationUuid"] as? String) ?? (oauth["organizationUuid"] as? String)) {
        payload["organizationUuid"] = organizationUuid
    }
    let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard let string = String(data: encoded, encoding: .utf8) else {
        return nil
    }
    return string
}

func claudeOAuthPayloadIsExpired(_ value: Any?) -> Bool {
    guard let milliseconds = expiresAtMilliseconds(value) else { return false }
    let expiresAt = Date(timeIntervalSince1970: milliseconds / 1_000)
    return expiresAt <= Date().addingTimeInterval(60)
}

func expiresAtMilliseconds(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String {
        if let double = Double(string) {
            return double
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date.timeIntervalSince1970 * 1_000
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date.timeIntervalSince1970 * 1_000
        }
    }
    return nil
}

let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let supportDirectory: URL
if let override = environment["OPENBURNBAR_DAEMON_SUPPORT_DIR"] ?? environment["BURNBAR_DAEMON_SUPPORT_DIR"],
   !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    supportDirectory = URL(fileURLWithPath: override, isDirectory: true)
} else {
    supportDirectory = home.appendingPathComponent("Library/Application Support/OpenBurnBar", isDirectory: true)
}
let socketPath = supportDirectory.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false).path
let tokenPath = supportDirectory.appendingPathComponent("daemon-socket-auth-token", isDirectory: false)

guard let authToken = try? String(contentsOf: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      !authToken.isEmpty else {
    fputs("Missing daemon socket auth token\n", stderr)
    exit(1)
}

var credentialCandidates: [String] = []
if environment["BURNBAR_DISABLE_CLAUDE_CODE_KEYCHAIN_FALLBACK"] != "1",
   let keychainPayload = readClaudeCodeKeychainPayload(account: NSUserName()) {
    credentialCandidates.append(keychainPayload)
}
for path in [
    home.appendingPathComponent(".claude/.credentials.json"),
    home.appendingPathComponent(".claude/credentials.json")
] {
    if let raw = try? String(contentsOf: path, encoding: .utf8),
       let trimmed = trimmedNonEmpty(raw) {
        credentialCandidates.append(trimmed)
    }
}

var apiKey: String?
for raw in credentialCandidates {
    if let normalized = try normalizedClaudeOAuthStoragePayload(from: raw) {
        apiKey = normalized
        break
    }
}
guard let apiKey else {
    fputs("No non-expired Claude Code OAuth token found in Keychain or ~/.claude/.credentials.json\n", stderr)
    exit(1)
}

let request = UpsertRequest(
    id: UUID().uuidString,
    method: "daemon.provider.credential_slot.upsert",
    authToken: authToken,
    params: UpsertParams(
        providerID: "anthropic",
        slotID: nil,
        label: "Claude Code OAuth",
        apiKey: apiKey,
        isEnabled: true,
        endpointProfileID: nil,
        region: nil,
        tokenPlanTier: nil,
        tokenPlanBillingCycle: nil,
        authMethodID: "anthropic-claude-oauth"
    )
)

let payloadData = try JSONEncoder().encode(request) + Data([0x0A])

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd != -1 else { perror("socket"); exit(1) }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { exit(1) }
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    pathBytes.withUnsafeBufferPointer { src in
        memcpy(ptr, src.baseAddress!, pathBytes.count)
    }
}

let connectResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
        connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connectResult == 0 else { perror("connect"); exit(1) }

try payloadData.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return }
    var remaining = raw.count
    var offset = 0
    while remaining > 0 {
        let written = write(fd, base.advanced(by: offset), remaining)
        guard written > 0 else { perror("write"); exit(1) }
        remaining -= written
        offset += written
    }
}

var response = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let readCount = read(fd, &buffer, buffer.count)
    if readCount <= 0 { break }
    response.append(contentsOf: buffer.prefix(readCount))
    if response.last == 0x0A { break }
}
while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

let envelope = try JSONDecoder().decode(RPCEnvelope<SlotMutationResponse>.self, from: response)
if let error = envelope.error {
    fputs("RPC error: \(error.message)\n", stderr)
    exit(1)
}
if let slotID = envelope.result?.slot.slotID {
    print("Upserted anthropic slot \(slotID)")
} else {
    fputs("Empty RPC result\n", stderr)
    exit(1)
}
