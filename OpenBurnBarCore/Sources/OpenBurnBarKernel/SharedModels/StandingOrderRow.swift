import Foundation

/// The persisted shape of a `StandingOrder` — the `standing_orders` table's row
/// and the Firestore document, in one type.
///
/// The mapping lives here rather than in the GRDB store so it can be tested
/// without a database, and so the local table and the cloud mirror cannot drift
/// into two different encodings of the same order.
///
/// The cadence is decomposed into a kind plus its components rather than
/// serialised as an opaque blob: a row stays readable in a SQL client, and a
/// corrupt or partial cadence is detectable instead of silently decoding into
/// the wrong schedule.
public struct StandingOrderRow: Sendable, Equatable, Codable {

    public enum CadenceKind: String, Sendable, Equatable, Codable, CaseIterable {
        case interval
        case daily
        case weekly
    }

    public var id: String
    public var title: String
    public var instruction: String
    public var cadenceKind: String
    public var cadenceMinutes: Int?
    public var cadenceHour: Int?
    public var cadenceMinute: Int?
    public var cadenceWeekday: Int?
    public var targetBodyId: String?
    /// Newline-joined, because a capability is a bare token with no spaces and
    /// this keeps the column greppable from SQL. Empty string means none.
    public var requiredCapabilities: String
    public var isEnabled: Bool
    public var lastFiredAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        instruction: String,
        cadenceKind: String,
        cadenceMinutes: Int? = nil,
        cadenceHour: Int? = nil,
        cadenceMinute: Int? = nil,
        cadenceWeekday: Int? = nil,
        targetBodyId: String? = nil,
        requiredCapabilities: String = "",
        isEnabled: Bool = true,
        lastFiredAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.cadenceKind = cadenceKind
        self.cadenceMinutes = cadenceMinutes
        self.cadenceHour = cadenceHour
        self.cadenceMinute = cadenceMinute
        self.cadenceWeekday = cadenceWeekday
        self.targetBodyId = targetBodyId
        self.requiredCapabilities = requiredCapabilities
        self.isEnabled = isEnabled
        self.lastFiredAt = lastFiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - From domain

    public init(order: StandingOrder, createdAt: Date, updatedAt: Date) {
        var kind: CadenceKind
        var minutes: Int?
        var hour: Int?
        var minute: Int?
        var weekday: Int?

        switch order.cadence {
        case let .everyMinutes(value):
            kind = .interval
            minutes = value
        case let .daily(h, m):
            kind = .daily
            hour = h
            minute = m
        case let .weekly(day, h, m):
            kind = .weekly
            weekday = day
            hour = h
            minute = m
        }

        self.init(
            id: order.id,
            title: order.title,
            instruction: order.instruction,
            cadenceKind: kind.rawValue,
            cadenceMinutes: minutes,
            cadenceHour: hour,
            cadenceMinute: minute,
            cadenceWeekday: weekday,
            targetBodyId: order.targetBodyID,
            requiredCapabilities: Self.encode(order.requiredCapabilities),
            isEnabled: order.isEnabled,
            lastFiredAt: order.lastFiredAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - To domain

    /// Rebuild the order, or nil when the row cannot describe a real schedule.
    ///
    /// A row whose cadence components are absent or out of range is dropped
    /// rather than coerced to a default: silently rescheduling somebody's
    /// nightly job to some other time is worse than not running it.
    public var order: StandingOrder? {
        guard let kind = CadenceKind(rawValue: cadenceKind) else { return nil }

        let cadence: StandingOrder.Cadence
        switch kind {
        case .interval:
            guard let minutes = cadenceMinutes, minutes > 0 else { return nil }
            cadence = .everyMinutes(minutes)
        case .daily:
            guard let hour = cadenceHour, let minute = cadenceMinute,
                  Self.isValidTime(hour: hour, minute: minute) else { return nil }
            cadence = .daily(hour: hour, minute: minute)
        case .weekly:
            guard let weekday = cadenceWeekday, let hour = cadenceHour, let minute = cadenceMinute,
                  (1...7).contains(weekday), Self.isValidTime(hour: hour, minute: minute) else { return nil }
            cadence = .weekly(weekday: weekday, hour: hour, minute: minute)
        }

        return StandingOrder(
            id: id,
            title: title,
            instruction: instruction,
            cadence: cadence,
            targetBodyID: targetBodyId,
            requiredCapabilities: Self.decode(requiredCapabilities),
            isEnabled: isEnabled,
            lastFiredAt: lastFiredAt
        )
    }

    // MARK: - Capabilities

    static func encode(_ capabilities: Set<String>) -> String {
        capabilities.sorted().joined(separator: "\n")
    }

    static func decode(_ raw: String) -> Set<String> {
        Set(
            raw.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func isValidTime(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }
}
