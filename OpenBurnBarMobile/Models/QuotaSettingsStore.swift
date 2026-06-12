import Foundation
import SwiftUI
import OpenBurnBarCore

public enum QuotaPercentageDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case remainingPercent
    case usedPercent
    case absoluteValues
    case fractional

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remainingPercent: return "Remaining % (e.g., 20%)"
        case .usedPercent: return "Used % (e.g., 80%)"
        case .absoluteValues: return "Absolute values (e.g., 4.0M / 20.0M)"
        case .fractional: return "Decimal fraction (e.g., 0.20)"
        }
    }
}

@Observable
@MainActor
public final class QuotaSettingsStore {
    private static let defaultProviderOrderCSV = AgentProvider.quotaSignalProviders
        .map(\.persistedToken)
        .joined(separator: ",")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.providerOrderCSV = defaults.string(forKey: "quota_providerOrderCSV") ?? Self.defaultProviderOrderCSV
        self.visibleProvidersCSV = defaults.string(forKey: "quota_visibleProvidersCSV") ?? Self.defaultProviderOrderCSV

        if let raw = defaults.string(forKey: "quota_hiddenBucketsJSON"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.hiddenBuckets = Set(decoded)
        } else {
            self.hiddenBuckets = []
        }

        if let raw = defaults.string(forKey: "quota_bucketOrdersJSON"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.bucketOrders = decoded
        } else {
            self.bucketOrders = [:]
        }

        if let raw = defaults.string(forKey: "quota_percentageDisplayMode"),
           let mode = QuotaPercentageDisplayMode(rawValue: raw) {
            self.percentageDisplayMode = mode
        } else {
            self.percentageDisplayMode = .remainingPercent
        }
    }

    private var providerOrderCSV: String {
        didSet { defaults.set(providerOrderCSV, forKey: "quota_providerOrderCSV") }
    }

    private var visibleProvidersCSV: String {
        didSet { defaults.set(visibleProvidersCSV, forKey: "quota_visibleProvidersCSV") }
    }

    public var hiddenBuckets: Set<String> {
        didSet {
            let array = Array(hiddenBuckets)
            if let data = try? JSONEncoder().encode(array),
               let raw = String(data: data, encoding: .utf8) {
                defaults.set(raw, forKey: "quota_hiddenBucketsJSON")
            }
        }
    }

    public var bucketOrders: [String: [String]] {
        didSet {
            if let data = try? JSONEncoder().encode(bucketOrders),
               let raw = String(data: data, encoding: .utf8) {
                defaults.set(raw, forKey: "quota_bucketOrdersJSON")
            }
        }
    }

    public var percentageDisplayMode: QuotaPercentageDisplayMode {
        didSet { defaults.set(percentageDisplayMode.rawValue, forKey: "quota_percentageDisplayMode") }
    }

    public var providerOrder: [AgentProvider] {
        get {
            let parsed = providerOrderCSV
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .compactMap { AgentProvider.fromPersistedToken($0) }
            if parsed.isEmpty {
                return AgentProvider.quotaSignalProviders
            }
            var deduped: [AgentProvider] = []
            for provider in parsed where !deduped.contains(provider) {
                deduped.append(provider)
            }
            for provider in AgentProvider.quotaSignalProviders where !deduped.contains(provider) {
                deduped.append(provider)
            }
            return deduped
        }
        set {
            providerOrderCSV = newValue.map(\.persistedToken).joined(separator: ",")
        }
    }

    public var visibleProviders: Set<AgentProvider> {
        get {
            let parsed = visibleProvidersCSV
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .compactMap { AgentProvider.fromPersistedToken($0) }
            if parsed.isEmpty {
                return Set(AgentProvider.quotaSignalProviders)
            }
            return Set(parsed)
        }
        set {
            visibleProvidersCSV = newValue.map(\.persistedToken).joined(separator: ",")
        }
    }
}
