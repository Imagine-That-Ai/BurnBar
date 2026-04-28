import Foundation

// MARK: - Settings Persistence Coordinator

/// Central coordinator for dirty-tracking, coalesced `UserDefaults` writes.
///
/// Domain stores delegate to this type rather than touching `UserDefaults` directly.
/// Mutations accumulate in a `Set<String>` of dirty keys and are flushed after a
/// short debounce (default 100 ms). This eliminates the old behavior where every
/// `didSet` triggered an unconditional 60-key atomic write.
@MainActor
final class SettingsPersistenceCoordinator {
    private let defaults: UserDefaults
    private var dirtyKeys: Set<String> = []
    private var pendingWrites: [String: () -> Void] = [:]
    private var pendingFlushTask: Task<Void, Never>?
    private let flushDelayNanoseconds: UInt64

    init(defaults: UserDefaults = .standard, flushDelayNanoseconds: UInt64 = 100_000_000) {
        self.defaults = defaults
        self.flushDelayNanoseconds = flushDelayNanoseconds
        OpenBurnBarMigration.migrateUserDefaults(defaults: defaults)
    }

    deinit {
        // Synchronously flush any pending writes on deallocation to avoid data loss.
        for key in dirtyKeys {
            pendingWrites.removeValue(forKey: key)?()
        }
        dirtyKeys.removeAll()
    }

    // MARK: - Typed Writers

    func set(_ value: Bool, forKey key: String) {
        pendingWrites[key] = { [defaults] in defaults.set(value, forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func set(_ value: Int, forKey key: String) {
        pendingWrites[key] = { [defaults] in defaults.set(value, forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func set(_ value: Double, forKey key: String) {
        pendingWrites[key] = { [defaults] in defaults.set(value, forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func set(_ value: String, forKey key: String) {
        pendingWrites[key] = { [defaults] in defaults.set(value, forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func set(_ value: Date, forKey key: String) {
        pendingWrites[key] = { [defaults] in defaults.set(value, forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func set<T: RawRepresentable>(_ value: T, forKey key: String) where T.RawValue == String {
        pendingWrites[key] = { [defaults] in defaults.set(value.rawValue, forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func removeObject(forKey key: String) {
        pendingWrites[key] = { [defaults] in defaults.removeObject(forKey: key) }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    // MARK: - Typed Readers

    func bool(forKey key: String, defaultValue: Bool = false) -> Bool {
        defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : defaultValue
    }

    func integer(forKey key: String, defaultValue: Int = 0) -> Int {
        defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : defaultValue
    }

    func double(forKey key: String, defaultValue: Double = 0) -> Double {
        defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : defaultValue
    }

    func string(forKey key: String, defaultValue: String = "") -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    func optionalString(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func optionalDouble(forKey key: String) -> Double? {
        defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : nil
    }

    func objectExists(forKey key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    func rawRepresentable<T: RawRepresentable>(forKey key: String, defaultValue: T) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else {
            return defaultValue
        }
        return value
    }

    // MARK: - Flush

    /// Immediately write all dirty keys to `UserDefaults`. Tests can call this to
    /// avoid waiting for the debounce interval.
    func flush() {
        for key in dirtyKeys {
            pendingWrites.removeValue(forKey: key)?()
        }
        dirtyKeys.removeAll()
        pendingFlushTask = nil
    }

    // MARK: - Private

    private func scheduleFlush() {
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.flushDelayNanoseconds ?? 100_000_000)
            await self?.flush()
        }
    }
}
