import Foundation
import CryptoKit
import Security

/// Thread-safe, two-tier cache for `InsightVerdict`.
///
/// Tier 1 is an in-memory dict for sub-16ms reads on every tab appear.
/// Tier 2 is a JSON-on-disk store keyed by (deviceID, window) so the
/// verdict survives launches. Reads always serve from memory; disk loads
/// happen lazily on first access for a key and are populated back into
/// memory.
///
/// The cache is opinionated about staleness: every read returns
/// `(verdict, isStale)` so the renderer can paint the cached entry
/// immediately while the composer kicks a background refresh.
public actor VerdictCache {

    public struct Read: Sendable {
        public let verdict: InsightVerdict
        public let isStale: Bool
        public let age: TimeInterval

        public init(verdict: InsightVerdict, isStale: Bool, age: TimeInterval) {
            self.verdict = verdict
            self.isStale = isStale
            self.age = age
        }
    }

    public enum Storage: Sendable {
        case memoryOnly
        case onDisk(directory: URL, encryptionKey: Data? = nil)

        public static func defaultUserCaches(subpath: String = "OpenBurnBar/Verdicts") -> Storage {
            let base = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return .onDisk(directory: base.appendingPathComponent(subpath, isDirectory: true))
        }
    }

    private let storage: Storage
    private let diskCrypto: VerdictCacheDiskCrypto?
    private let calendar: Calendar
    /// In-memory: deviceID -> Window -> dayBucketKey -> Verdict.
    private var memory: [String: [VerdictWindow: [String: InsightVerdict]]] = [:]
    /// Keys whose disk content has already been hydrated into memory.
    private var hydrated: Set<String> = []

    public init(storage: Storage = .defaultUserCaches(), calendar: Calendar = .current) {
        self.storage = storage
        self.calendar = calendar
        if case .onDisk(_, let encryptionKey) = storage {
            self.diskCrypto = VerdictCacheDiskCrypto.make(encryptionKey: encryptionKey)
        } else {
            self.diskCrypto = nil
        }
        if case .onDisk(let directory, _) = storage {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Read / Write

    public func read(
        window: VerdictWindow,
        deviceID: String,
        now: Date = Date()
    ) -> Read? {
        hydrateIfNeeded(window: window, deviceID: deviceID)
        let bucket = window.dayBucketKey(for: now, calendar: calendar)
        guard let verdict = memory[deviceID]?[window]?[bucket] else { return nil }
        let age = now.timeIntervalSince(verdict.generatedAt)
        return Read(
            verdict: verdict,
            isStale: age >= window.cacheTTL,
            age: age
        )
    }

    /// Read the most recent entry for a window even when the user is past
    /// the bucket boundary — used by the renderer to avoid blanking the
    /// surface when the calendar rolls over mid-session.
    public func readMostRecent(
        window: VerdictWindow,
        deviceID: String,
        now: Date = Date()
    ) -> Read? {
        hydrateIfNeeded(window: window, deviceID: deviceID)
        guard let buckets = memory[deviceID]?[window] else { return nil }
        let verdict = buckets.values.max(by: { $0.generatedAt < $1.generatedAt })
        guard let verdict else { return nil }
        let age = now.timeIntervalSince(verdict.generatedAt)
        return Read(
            verdict: verdict,
            isStale: age >= window.cacheTTL,
            age: age
        )
    }

    public func write(
        _ verdict: InsightVerdict,
        deviceID: String,
        now: Date = Date()
    ) {
        let bucket = verdict.window.dayBucketKey(for: verdict.generatedAt, calendar: calendar)
        memory[deviceID, default: [:]][verdict.window, default: [:]][bucket] = verdict
        persist(window: verdict.window, deviceID: deviceID)
    }

    public func clear(deviceID: String? = nil) {
        if let deviceID {
            memory[deviceID] = nil
        } else {
            memory.removeAll()
            hydrated.removeAll()
        }
        if case .onDisk(let directory, _) = storage {
            if let deviceID {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent("\(safeName(deviceID))")
                )
            } else {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    /// Number of cached verdicts for a (deviceID, window). Used by tests
    /// and the audit log.
    public func count(deviceID: String, window: VerdictWindow) -> Int {
        hydrateIfNeeded(window: window, deviceID: deviceID)
        return memory[deviceID]?[window]?.count ?? 0
    }

    // MARK: - Persistence

    private func hydrateIfNeeded(window: VerdictWindow, deviceID: String) {
        let key = "\(deviceID)/\(window.rawValue)"
        guard !hydrated.contains(key) else { return }
        defer { hydrated.insert(key) }
        guard case .onDisk(let directory, _) = storage,
              let diskCrypto else { return }
        let url = fileURL(in: directory, deviceID: deviceID, window: window)
        let legacyURL = legacyFileURL(in: directory, deviceID: deviceID, window: window)
        let dict: [String: InsightVerdict]?
        if FileManager.default.fileExists(atPath: url.path),
           let sealedData = try? Data(contentsOf: url),
           let opened = try? diskCrypto.open(sealedData, associatedData: associatedData(deviceID: deviceID, window: window)) {
            dict = try? JSONDecoder.verdict.decode([String: InsightVerdict].self, from: opened)
        } else if FileManager.default.fileExists(atPath: legacyURL.path),
                  let legacyData = try? Data(contentsOf: legacyURL),
                  let legacy = try? JSONDecoder.verdict.decode([String: InsightVerdict].self, from: legacyData) {
            dict = legacy
        } else {
            dict = nil
        }
        guard let dict else { return }
        memory[deviceID, default: [:]][window] = dict
        persist(window: window, deviceID: deviceID)
    }

    private func persist(window: VerdictWindow, deviceID: String) {
        guard case .onDisk(let directory, _) = storage,
              let diskCrypto else { return }
        guard let dict = memory[deviceID]?[window] else { return }
        let url = fileURL(in: directory, deviceID: deviceID, window: window)
        let legacyURL = legacyFileURL(in: directory, deviceID: deviceID, window: window)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(dict),
              let sealed = try? diskCrypto.seal(data, associatedData: associatedData(deviceID: deviceID, window: window))
        else { return }
        try? sealed.write(to: url, options: [.atomic])
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private func fileURL(in directory: URL, deviceID: String, window: VerdictWindow) -> URL {
        let safeID = safeName(deviceID)
        let dir = directory.appendingPathComponent(safeID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(window.rawValue).sealed")
    }

    private func legacyFileURL(in directory: URL, deviceID: String, window: VerdictWindow) -> URL {
        let safeID = safeName(deviceID)
        let dir = directory.appendingPathComponent(safeID, isDirectory: true)
        return dir.appendingPathComponent("\(window.rawValue).json")
    }

    private func associatedData(deviceID: String, window: VerdictWindow) -> Data {
        Data("com.openburnbar.insights.verdict-cache.v1|\(safeName(deviceID))|\(window.rawValue)".utf8)
    }

    private func safeName(_ raw: String) -> String {
        raw.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }
}

private struct VerdictCacheDiskCrypto: Sendable {
    private static let magic = Data("OBBVERDICTCACHE1\n".utf8)
    private static let keychainService = "com.openburnbar.insights.verdict-cache"
    private static let keychainAccount = "verdict-cache-aes-gcm-v1"

    private let key: SymmetricKey

    static func make(encryptionKey: Data?) -> VerdictCacheDiskCrypto? {
        if let encryptionKey, encryptionKey.count == 32 {
            return VerdictCacheDiskCrypto(key: SymmetricKey(data: encryptionKey))
        }
        guard let keyData = loadOrCreateKeychainKey() else { return nil }
        return VerdictCacheDiskCrypto(key: SymmetricKey(data: keyData))
    }

    func seal(_ plaintext: Data, associatedData: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: associatedData
        ).combined else {
            throw VerdictCacheDiskCryptoError.missingCombinedBox
        }
        return Self.magic + combined
    }

    func open(_ envelope: Data, associatedData: Data) throws -> Data {
        guard envelope.starts(with: Self.magic) else {
            throw VerdictCacheDiskCryptoError.badMagic
        }
        let box = try AES.GCM.SealedBox(combined: envelope.dropFirst(Self.magic.count))
        return try AES.GCM.open(box, using: key, authenticating: associatedData)
    }

    private static func loadOrCreateKeychainKey() -> Data? {
        if let existing = keychainRead() {
            return existing.count == 32 ? existing : nil
        }
        var keyData = Data(count: 32)
        let status = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        guard keychainWrite(keyData) else { return nil }
        return keyData
    }

    private static func keychainRead() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func keychainWrite(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(create as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}

private enum VerdictCacheDiskCryptoError: Error {
    case badMagic
    case missingCombinedBox
}

private extension JSONDecoder {
    static let verdict: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
