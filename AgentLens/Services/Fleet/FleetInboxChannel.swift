import OpenBurnBarKernel
import Foundation

/// BurnBar-owned fleet inbox. The durable write path for **every** roster
/// CLI and **every** thread: `…/fleet-inbox/<agent>/<sessionRef>.jsonl`
/// with mode 0600. A successful append is `submitted`, never `delivered`.
final class FleetInboxChannel: BurnBarFleetDirectiveChannel, Sendable {
    let inboxRoot: URL
    private let fileManager: FileManager

    init(
        inboxRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        if let inboxRoot {
            self.inboxRoot = inboxRoot
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.inboxRoot = support
                .appendingPathComponent("BurnBar", isDirectory: true)
                .appendingPathComponent("fleet-inbox", isDirectory: true)
        }
        self.fileManager = fileManager
    }

    var channelName: String { "fleet-inbox" }

    func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
        BurnBarFleetAgentID.declaredRoster.contains(targetAgent)
    }

    func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
        guard let agent = directive.targetAgent, supports(targetAgent: agent) else {
            return .unsupported(reason: "Inbox requires a declared roster target agent.")
        }
        let rawRef = directive.sessionRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionRef = sanitizedFileName(rawRef?.isEmpty == false ? rawRef! : "inbox")
        guard let sessionRef else {
            return .failed(reason: "sessionRef is not a safe inbox file name.")
        }
        let directory = inboxRoot.appendingPathComponent(agent.wireValue, isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(sessionRef).jsonl")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = try encodeLine(directive, sessionRef: sessionRef)
            if fileManager.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer {
                    // try?-ok(best-effort close after inbox append)
                    _ = try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return .submitted
        } catch {
            return .failed(reason: "inbox write failed: \(error.localizedDescription)")
        }
    }

    static func sanitizedFileName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return nil }
        return trimmed
    }

    private func sanitizedFileName(_ raw: String) -> String? {
        Self.sanitizedFileName(raw)
    }

    private func encodeLine(_ directive: BurnBarFleetDirective, sessionRef: String) throws -> Data {
        let envelope: [String: String] = [
            "id": directive.id,
            "kind": directive.kind.rawValue,
            "targetAgent": directive.targetAgent?.wireValue ?? "",
            "sessionRef": sessionRef,
            "payload": directive.payload,
            "createdAt": ISO8601DateFormatter().string(from: directive.createdAt)
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        var line = data
        line.append(contentsOf: "\n".utf8)
        return line
    }
}
