import Foundation

/// Structured audit events for privileged UNIX-domain sockets (Virtual HID bridge, root agent).
public enum PrivilegedSocketAuditEvent: String, Codable, Sendable {
    case peerAccepted = "privileged_socket_peer_accepted"
    case peerRejected = "privileged_socket_peer_rejected"
    case bridgeInputAccepted = "privileged_bridge_input_accepted"
    case bridgeInputRejected = "privileged_bridge_input_rejected"
}

public struct PrivilegedSocketAuditRecord: Codable, Sendable, Equatable {
    public var event: PrivilegedSocketAuditEvent
    public var timestamp: Date
    public var socket: String
    public var operation: String?
    public var detail: String?
    public var peerUID: UInt32?
    public var inputKind: String?

    public init(
        event: PrivilegedSocketAuditEvent,
        timestamp: Date = Date(),
        socket: String,
        operation: String? = nil,
        detail: String? = nil,
        peerUID: UInt32? = nil,
        inputKind: String? = nil
    ) {
        self.event = event
        self.timestamp = timestamp
        self.socket = socket
        self.operation = operation
        self.detail = detail
        self.peerUID = peerUID
        self.inputKind = inputKind
    }
}

/// Append-only JSONL audit sink for privileged socket decisions. Writes one line per event to
/// stderr so launchd captures it in the service log (audit-dark channel remediation).
public enum PrivilegedSocketAudit {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
            try container.encode(ms)
        }
        return encoder
    }()

    public static func record(_ record: PrivilegedSocketAuditRecord) {
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        let message = "privileged_socket_audit \(line)\n"
        guard let bytes = message.data(using: .utf8) else { return }
        FileHandle.standardError.write(bytes)
    }
}
