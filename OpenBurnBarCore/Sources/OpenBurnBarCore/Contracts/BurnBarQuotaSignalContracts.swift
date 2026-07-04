import Foundation

public struct BurnBarQuotaSignalHeader: Codable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct BurnBarQuotaSignalRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let observedAt: Date
    public let signalTier: QuotaSignalTier
    public let providerID: String
    public let providerName: String?
    public let accountID: String?
    public let accountLabel: String?
    public let credentialSlotID: String?
    public let endpointProfileID: String?
    public let requestPath: String?
    public let endpoint: String?
    public let modelID: String?
    public let upstreamModelID: String?
    public let formatFamily: String?
    public let httpStatus: Int?
    public let streamed: Bool
    public let headers: [BurnBarQuotaSignalHeader]
    public let remaining: Int?
    public let limit: Int?
    public let resetsAt: Date?

    public init(
        id: String = UUID().uuidString,
        observedAt: Date,
        signalTier: QuotaSignalTier = .trafficHeaders,
        providerID: String,
        providerName: String? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        credentialSlotID: String? = nil,
        endpointProfileID: String? = nil,
        requestPath: String? = nil,
        endpoint: String? = nil,
        modelID: String? = nil,
        upstreamModelID: String? = nil,
        formatFamily: String? = nil,
        httpStatus: Int? = nil,
        streamed: Bool = false,
        headers: [BurnBarQuotaSignalHeader],
        remaining: Int? = nil,
        limit: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.signalTier = signalTier
        self.providerID = providerID
        self.providerName = providerName
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.credentialSlotID = credentialSlotID
        self.endpointProfileID = endpointProfileID
        self.requestPath = requestPath
        self.endpoint = endpoint
        self.modelID = modelID
        self.upstreamModelID = upstreamModelID
        self.formatFamily = formatFamily
        self.httpStatus = httpStatus
        self.streamed = streamed
        self.headers = headers
        self.remaining = remaining
        self.limit = limit
        self.resetsAt = resetsAt
    }
}

public struct BurnBarQuotaSignalsRecentRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }
}

public struct BurnBarQuotaSignalsRecentResponse: Codable, Hashable, Sendable {
    public let signals: [BurnBarQuotaSignalRecord]

    public init(signals: [BurnBarQuotaSignalRecord]) {
        self.signals = signals
    }
}

public struct BurnBarQuotaSignalsClearRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarQuotaSignalsClearResponse: Codable, Hashable, Sendable {
    public let cleared: Bool

    public init(cleared: Bool) {
        self.cleared = cleared
    }
}
