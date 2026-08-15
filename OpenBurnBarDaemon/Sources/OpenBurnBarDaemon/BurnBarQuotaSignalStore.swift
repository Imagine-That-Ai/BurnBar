import OpenBurnBarEngine
import Foundation

public actor BurnBarQuotaSignalStore {
    public static let defaultRecentLimit = 50
    public static let maxRecentLimit = 200
    public static let retainedRecordLimit = 5_000

    private let fileURL: URL
    private let logger: BurnBarDaemonLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedSignals: [BurnBarQuotaSignalRecord]?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultQuotaSignalsURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "quota-signals")
    ) {
        self.fileURL = fileURL
        self.logger = logger
    }

    public func append(_ signal: BurnBarQuotaSignalRecord) async {
        do {
            var signals = try loadSignals()
            signals.append(signal)
            if signals.count > Self.retainedRecordLimit {
                signals = Array(signals.suffix(Self.retainedRecordLimit))
                try rewrite(signals)
            } else {
                try appendLine(signal)
            }
            cachedSignals = signals
        } catch {
            logger.silentFailure("quota_signal_append", error: error)
        }
    }

    public func recent(limit: Int = BurnBarQuotaSignalStore.defaultRecentLimit) throws -> [BurnBarQuotaSignalRecord] {
        let boundedLimit = min(max(0, limit), Self.maxRecentLimit)
        return Array(
            try loadSignals()
                .sorted { $0.observedAt > $1.observedAt }
                .prefix(boundedLimit)
        )
    }

    public static func providerSnapshots(
        from signals: [BurnBarQuotaSignalRecord],
        now: Date = Date(),
        staleAfter: TimeInterval = 15 * 60
    ) -> [ProviderQuotaSnapshot] {
        var latest: [String: BurnBarQuotaSignalRecord] = [:]
        for signal in signals {
            let providerID = signal.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !providerID.isEmpty, !quotaBuckets(from: signal).isEmpty else { continue }
            let groupingKey = ProviderID(rawValue: providerID).rawValue
            if latest[groupingKey].map({ $0.observedAt >= signal.observedAt }) == true { continue }
            latest[groupingKey] = signal
        }

        return latest.values.compactMap { signal in
            let coverage = signal.signalTier.linuxQuotaCoverage
            let confidence: ProviderQuotaConfidence = now.timeIntervalSince(signal.observedAt) > staleAfter ? .stale : .high
            let providerID = signal.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = ProviderQuotaSnapshot(
                id: "linux-header-\(providerID)-\(signal.accountID ?? "provider")",
                provider: providerID,
                providerID: ProviderID(rawValue: providerID),
                accountID: signal.accountID,
                accountLabel: signal.accountLabel,
                sourceKind: coverage.sourceKind,
                sourceId: "daemon.quota.signals:\(signal.id)",
                fetchedAt: signal.observedAt,
                source: coverage.sourceLabel,
                confidence: confidence,
                statusMessage: confidence == .stale ? "Last provider quota signal is stale." : nil,
                buckets: quotaBuckets(from: signal),
                updatedAt: signal.observedAt
            )
            return ProviderQuotaSnapshotValidator.accepted(
                snapshot,
                expectedProvider: ProviderID(rawValue: providerID),
                now: now
            )
        }
        .sorted { $0.providerID.rawValue < $1.providerID.rawValue }
    }

    private static func quotaBuckets(from signal: BurnBarQuotaSignalRecord) -> [ProviderQuotaBucket] {
        let families: [(token: String, label: String, unit: ProviderQuotaUnit)] = [
            ("requests", "Request rate limit", .requests),
            ("tokens", "Token rate limit", .tokens)
        ]
        var buckets: [ProviderQuotaBucket] = []
        for family in families {
            let limitHeader = signal.headers.first { header($0.name, contains: "limit", family: family.token) }
            let remainingHeader = signal.headers.first { header($0.name, contains: "remaining", family: family.token) }
            guard let limit = limitHeader.flatMap({ integerPrefix(from: $0.value) }),
                  let remaining = remainingHeader.flatMap({ integerPrefix(from: $0.value) }),
                  limit > 0, remaining >= 0, remaining <= limit else { continue }
            let reset = signal.headers.first { header($0.name, contains: "reset", family: family.token) }
                .flatMap { resetDate(from: $0.value, name: $0.name, observedAt: signal.observedAt) }
            buckets.append(bucket(
                key: "traffic-\(family.token)-rate-limit",
                label: family.label,
                unit: family.unit,
                remaining: remaining,
                limit: limit,
                resetsAt: reset
            ))
        }
        if !buckets.isEmpty { return buckets }
        guard let remaining = signal.remaining, let limit = signal.limit,
              limit > 0, remaining >= 0, remaining <= limit else { return [] }
        return [bucket(
            key: "traffic-unknown-rate-limit",
            label: "Provider rate limit",
            unit: .unknown,
            remaining: remaining,
            limit: limit,
            resetsAt: signal.resetsAt
        )]
    }

    private static func header(_ name: String, contains metric: String, family: String) -> Bool {
        let components = name.lowercased().split(separator: "-").map(String.init)
        return components.contains(metric) && components.contains(family)
    }

    private static func bucket(
        key: String,
        label: String,
        unit: ProviderQuotaUnit,
        remaining: Int,
        limit: Int,
        resetsAt: Date?
    ) -> ProviderQuotaBucket {
        let limitValue = Double(limit)
        let remainingValue = Double(remaining)
        let usedValue = limitValue - remainingValue
        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: .custom,
            usedValue: usedValue,
            limitValue: limitValue,
            remainingValue: remainingValue,
            usedPercent: min(100, max(0, usedValue / limitValue * 100)),
            resetsAt: resetsAt,
            unit: unit,
            isEstimated: false
        )
    }

    private static func resetDate(from raw: String, name: String, observedAt: Date) -> Date? {
        if let date = iso8601Date(from: raw) { return date }
        if let seconds = TimeInterval(raw) {
            return seconds < 1_000_000_000
                ? observedAt.addingTimeInterval(seconds)
                : Date(timeIntervalSince1970: seconds)
        }
        return durationInterval(from: raw).map { observedAt.addingTimeInterval($0) }
    }

    public func clear() throws {
        cachedSignals = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public static func signal(
        from headers: [String: String],
        route: BurnBarProviderRoute,
        requestPath: String?,
        endpoint: String?,
        httpStatus: Int?,
        streamed: Bool,
        observedAt: Date = Date()
    ) -> BurnBarQuotaSignalRecord? {
        let quotaHeaders = quotaHeaders(from: headers)
        guard !quotaHeaders.isEmpty else { return nil }

        return BurnBarQuotaSignalRecord(
            observedAt: observedAt,
            providerID: route.providerID,
            providerName: route.providerDisplayName,
            accountID: route.credentialSlotID,
            accountLabel: route.credentialSlotLabel,
            credentialSlotID: route.credentialSlotID,
            endpointProfileID: route.endpointProfileID,
            requestPath: requestPath,
            endpoint: endpoint,
            modelID: route.requestedModel,
            upstreamModelID: route.resolvedModelID,
            formatFamily: route.formatFamily.rawValue,
            httpStatus: httpStatus,
            streamed: streamed,
            headers: quotaHeaders,
            remaining: firstIntegerHeader(namedLike: "remaining", in: quotaHeaders),
            limit: firstIntegerHeader(namedLike: "limit", in: quotaHeaders),
            resetsAt: firstResetDate(in: quotaHeaders, observedAt: observedAt)
        )
    }

    public static func quotaHeaders(from headers: [String: String]) -> [BurnBarQuotaSignalHeader] {
        headers.compactMap { key, value -> BurnBarQuotaSignalHeader? in
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = name.lowercased()
            guard isAllowedQuotaHeaderName(normalized) else { return nil }
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            let boundedValue = String(trimmedValue.prefix(512))
            return BurnBarQuotaSignalHeader(name: normalized, value: boundedValue)
        }
        .sorted { lhs, rhs in lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name }
    }

    private static func isAllowedQuotaHeaderName(_ normalized: String) -> Bool {
        normalized.hasPrefix("anthropic-ratelimit-")
            || normalized.hasPrefix("x-ratelimit-")
            || normalized.hasPrefix("ratelimit-")
            || normalized == "retry-after"
    }

    private static func firstIntegerHeader(
        namedLike marker: String,
        in headers: [BurnBarQuotaSignalHeader]
    ) -> Int? {
        for header in headers where headerName(header.name, matchesTerminalComponent: marker) {
            if let integer = integerPrefix(from: header.value) {
                return integer
            }
        }
        return nil
    }

    private static func firstResetDate(
        in headers: [BurnBarQuotaSignalHeader],
        observedAt: Date
    ) -> Date? {
        for header in headers where headerName(header.name, matchesTerminalComponent: "reset") || header.name == "retry-after" {
            if let date = iso8601Date(from: header.value) {
                return date
            }
            if let seconds = TimeInterval(header.value) {
                if header.name == "retry-after" || seconds < 1_000_000_000 {
                    return observedAt.addingTimeInterval(seconds)
                }
                return Date(timeIntervalSince1970: seconds)
            }
            if let duration = durationInterval(from: header.value) {
                return observedAt.addingTimeInterval(duration)
            }
        }
        return nil
    }

    private static func headerName(_ name: String, matchesTerminalComponent marker: String) -> Bool {
        name == marker || name.hasSuffix("-\(marker)")
    }

    private static func integerPrefix(from raw: String) -> Int? {
        let prefix = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isNumber }
        guard !prefix.isEmpty else { return nil }
        return Int(prefix)
    }

    private static func iso8601Date(from raw: String) -> Date? {
        if let date = ThreadSafeISO8601DateFormatter.parseBasic(raw) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }

    private static func durationInterval(from raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [(suffix: String, multiplier: TimeInterval)] = [
            ("ms", 0.001),
            ("s", 1),
            ("m", 60),
            ("h", 3_600),
            ("d", 86_400)
        ]
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            let numberPart = trimmed.dropLast(unit.suffix.count)
            guard let value = TimeInterval(numberPart), value >= 0 else { return nil }
            return value * unit.multiplier
        }
        return nil
    }

    private func loadSignals() throws -> [BurnBarQuotaSignalRecord] {
        if let cachedSignals {
            return cachedSignals
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedSignals = []
            return []
        }

        let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
        var signals: [BurnBarQuotaSignalRecord] = []
        var corruptLineCount = 0
        for line in fileContents.split(whereSeparator: \.isNewline) {
            do {
                let signal = try decoder.decode(BurnBarQuotaSignalRecord.self, from: Data(line.utf8))
                signals.append(signal)
            } catch {
                corruptLineCount += 1
            }
        }
        if corruptLineCount > 0 {
            logger.warning(
                "quota_signal_corrupt_lines_skipped",
                metadata: ["count": "\(corruptLineCount)"]
            )
        }
        if signals.count > Self.retainedRecordLimit {
            signals = Array(signals.suffix(Self.retainedRecordLimit))
            try rewrite(signals)
        }
        cachedSignals = signals
        return signals
    }

    private func appendLine(_ signal: BurnBarQuotaSignalRecord) throws {
        try ensureDirectory()
        let encodedRecord = try encoder.encode(signal) + Data([0x0A])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encodedRecord)
        } else {
            try encodedRecord.write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func rewrite(_ signals: [BurnBarQuotaSignalRecord]) throws {
        try ensureDirectory()
        let data = try signals.reduce(into: Data()) { partial, signal in
            partial.append(try encoder.encode(signal))
            partial.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
