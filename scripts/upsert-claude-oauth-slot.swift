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

struct RPCError: Codable { let code: String; let message: String }
struct RPCEnvelope<T: Codable>: Codable {
    let id: String
    let result: T?
    let error: RPCError?
}

struct SlotMutationResponse: Codable {
    let slot: Slot
    struct Slot: Codable { let slotID: String }
}

let home = FileManager.default.homeDirectoryForCurrentUser
let socketPath = home.appendingPathComponent("Library/Application Support/OpenBurnBar/openburnbar-daemon.sock").path
let tokenPath = home.appendingPathComponent("Library/Application Support/OpenBurnBar/daemon-socket-auth-token")
let credsPath = home.appendingPathComponent(".claude/.credentials.json")

guard let authToken = try? String(contentsOf: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      !authToken.isEmpty else {
    fputs("Missing daemon socket auth token\n", stderr)
    exit(1)
}

guard let credsData = try? Data(contentsOf: credsPath),
      let credsRoot = try? JSONSerialization.jsonObject(with: credsData) as? [String: Any] else {
    fputs("Missing ~/.claude/.credentials.json\n", stderr)
    exit(1)
}

let oauth = credsRoot["claudeAiOauth"] as? [String: Any] ?? credsRoot
guard let accessToken = oauth["accessToken"] as? String,
      !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fputs("Missing non-empty Claude OAuth accessToken in ~/.claude/.credentials.json\n", stderr)
    exit(1)
}
var payload: [String: Any] = ["claudeAiOauth": oauth]
if let org = credsRoot["organizationUuid"] as? String { payload["organizationUuid"] = org }
let apiKeyData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
guard let apiKey = String(data: apiKeyData, encoding: .utf8) else { exit(1) }

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
