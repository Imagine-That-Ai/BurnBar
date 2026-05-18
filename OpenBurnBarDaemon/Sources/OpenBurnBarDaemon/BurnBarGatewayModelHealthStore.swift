import OpenBurnBarCore
import Foundation

public struct BurnBarGatewayModelHealthRecord: Codable, Hashable, Sendable {
    public let modelID: String
    public let providerID: String
    public let accountID: String
    public let accountLabel: String
    public let formatFamily: BurnBarProviderFormatFamily
    public let statusCode: Int
    public let message: String
    public let failedAt: Date
    public let blockedUntil: Date

    public var isActive: Bool {
        blockedUntil > Date()
    }
}

public actor BurnBarGatewayModelHealthStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let clock: @Sendable () -> Date
    private var loadedRecords: [String: BurnBarGatewayModelHealthRecord]?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultGatewayModelHealthURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func activeFailure(
        modelID: String,
        providerID: String,
        accountID: String,
        formatFamily: BurnBarProviderFormatFamily
    ) -> BurnBarGatewayModelHealthRecord? {
        var records = loadRecords()
        let now = clock()
        let lookupKey = key(
            modelID: modelID,
            providerID: providerID,
            accountID: accountID,
            formatFamily: formatFamily
        )
        guard let record = records[lookupKey] else { return nil }
        guard record.blockedUntil > now else {
            records.removeValue(forKey: lookupKey)
            loadedRecords = records
            persist(records)
            return nil
        }
        return record
    }

    public func recordSuccess(
        modelID: String,
        formatFamily: BurnBarProviderFormatFamily,
        route: BurnBarProviderRoute
    ) {
        let accountID = route.credentialSlotID ?? "legacy"
        var records = loadRecords()
        let lookupKey = key(
            modelID: modelID,
            providerID: route.providerID,
            accountID: accountID,
            formatFamily: formatFamily
        )
        guard records.removeValue(forKey: lookupKey) != nil else { return }
        loadedRecords = records
        persist(records)
    }

    public func recordFailure(
        modelID: String,
        formatFamily: BurnBarProviderFormatFamily,
        route: BurnBarProviderRoute,
        error: Error
    ) {
        guard let providerError = error as? BurnBarProviderExecutorError,
              case .upstreamError(let statusCode, let body) = providerError,
              let duration = Self.blockDuration(statusCode: statusCode, body: body, route: route) else {
            return
        }

        let now = clock()
        let accountID = route.credentialSlotID ?? "legacy"
        let accountLabel = route.credentialSlotLabel ?? route.providerDisplayName
        let message = Self.routeFailureMessage(
            modelID: modelID,
            statusCode: statusCode,
            body: body,
            route: route
        )
        let record = BurnBarGatewayModelHealthRecord(
            modelID: modelID,
            providerID: route.providerID,
            accountID: accountID,
            accountLabel: accountLabel,
            formatFamily: formatFamily,
            statusCode: statusCode,
            message: message,
            failedAt: now,
            blockedUntil: now.addingTimeInterval(duration)
        )
        var records = loadRecords()
        records[key(
            modelID: modelID,
            providerID: route.providerID,
            accountID: accountID,
            formatFamily: formatFamily
        )] = record
        loadedRecords = records
        persist(records)
    }

    public static func routeFailureMessage(
        modelID: String,
        statusCode: Int,
        body: String,
        route: BurnBarProviderRoute
    ) -> String {
        let accountLabel = route.credentialSlotLabel ?? route.providerDisplayName
        let upstreamMessage = upstreamMessage(from: body)
        if statusCode == 429,
           isAnthropicOAuth(route),
           isOpaque(upstreamMessage) {
            // BurnBar already presents the Claude Code identity (beta header
            // + system guard) on this OAuth route, so the public Messages
            // API has nothing more to gate on — a 429 here is a genuine
            // usage signal, not a "you're not Claude Code" rejection.
            return "\(route.providerDisplayName) Claude Max account '\(accountLabel)' returned HTTP 429 for \(modelID). BurnBar already identifies as Claude Code on this route, so this is most likely a Claude Max usage cap (Anthropic's public Messages API returns an opaque rate_limit_error without distinguishing quota from other gating). BurnBar will stop advertising this model for this account until the cooldown passes; choose another advertised model or wait for the Claude Max window to reset."
        }
        if let upstreamMessage,
           !upstreamMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(route.providerDisplayName) account '\(accountLabel)' returned HTTP \(statusCode) for \(modelID): \(upstreamMessage)"
        }
        return "\(route.providerDisplayName) account '\(accountLabel)' returned HTTP \(statusCode) for \(modelID)."
    }

    private static func blockDuration(
        statusCode: Int,
        body: String,
        route: BurnBarProviderRoute
    ) -> TimeInterval? {
        let lowerBody = body.lowercased()
        if statusCode == 429 {
            return isAnthropicOAuth(route) ? 15 * 60 : 5 * 60
        }
        if statusCode == 401 || statusCode == 403 {
            return 60 * 60
        }
        if statusCode == 402
            || lowerBody.contains("quota")
            || lowerBody.contains("insufficient")
            || lowerBody.contains("exhaust") {
            return 30 * 60
        }
        return nil
    }

    private static func upstreamMessage(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return trimmed
        }
        if let dictionary = object as? [String: Any] {
            if let message = dictionary["message"] as? String {
                return message
            }
            if let error = dictionary["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let error = dictionary["error"] as? String {
                return error
            }
        }
        return trimmed
    }

    private static func isOpaque(_ message: String?) -> Bool {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return true
        }
        let lowered = message.lowercased()
        return lowered == "error" || lowered == "rate limit error"
    }

    private static func isAnthropicOAuth(_ route: BurnBarProviderRoute) -> Bool {
        route.providerID.caseInsensitiveCompare("anthropic") == .orderedSame
            && route.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sk-ant-oat")
    }

    private func loadRecords() -> [String: BurnBarGatewayModelHealthRecord] {
        if let loadedRecords {
            return loadedRecords
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([String: BurnBarGatewayModelHealthRecord].self, from: data) else {
            loadedRecords = [:]
            return [:]
        }
        let now = clock()
        let active = decoded.filter { $0.value.blockedUntil > now }
        loadedRecords = active
        if active.count != decoded.count {
            persist(active)
        }
        return active
    }

    private func persist(_ records: [String: BurnBarGatewayModelHealthRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Model health is a routing hint. A persistence miss must never
            // break the user's request path.
        }
    }

    private func key(
        modelID: String,
        providerID: String,
        accountID: String,
        formatFamily: BurnBarProviderFormatFamily
    ) -> String {
        [
            providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            formatFamily.rawValue,
            modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "#")
    }
}
