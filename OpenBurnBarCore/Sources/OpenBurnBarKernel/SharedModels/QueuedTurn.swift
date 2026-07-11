import Foundation

// MARK: - Queued Turn (Hermes Square §6.8)
//
// Composer queue item — a follow-up turn the user types while turn N-1
// is still running. Source pattern: Replit Queue
// (https://blog.replit.com/introducing-queue-a-smarter-way-to-work-with-agent).
//
// Plain value type. The composer owns a `[QueuedTurn]` array and pops the
// head each time the agent finishes a turn. Cross-platform shape.

public struct QueuedTurn: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// Text the user typed for this queued turn.
    public var text: String
    /// IDs of any attachments the user dropped in (file URIs, image paths).
    public var attachmentIDs: [String]
    /// ISO timestamp when the turn was queued.
    public let queuedAt: Date
    /// Sequence number for stable ordering. Lower = earlier.
    public var sequence: Int
    /// State the queue UI renders against.
    public var state: State

    public enum State: Codable, Sendable, Hashable {
        case pending          // queued, not yet sent
        case inFlight         // currently being processed
        case completed
        case cancelled
        case failed(reasonHash: Int) // simple discriminator for hashable

        public var displayLabel: String {
            switch self {
            case .pending:   return "Queued"
            case .inFlight:  return "Running"
            case .completed: return "Done"
            case .cancelled: return "Cancelled"
            case .failed:    return "Failed"
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .completed, .cancelled, .failed: return true
            case .pending, .inFlight: return false
            }
        }

        // Codable round-trip for the associated value
        private enum CodingKeys: String, CodingKey {
            case kind, reasonHash
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .kind)
            switch kind {
            case "pending": self = .pending
            case "inFlight": self = .inFlight
            case "completed": self = .completed
            case "cancelled": self = .cancelled
            case "failed":
                self = .failed(reasonHash: (try? c.decode(Int.self, forKey: .reasonHash)) ?? 0)
            default:
                self = .pending
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending:   try c.encode("pending", forKey: .kind)
            case .inFlight:  try c.encode("inFlight", forKey: .kind)
            case .completed: try c.encode("completed", forKey: .kind)
            case .cancelled: try c.encode("cancelled", forKey: .kind)
            case .failed(let h):
                try c.encode("failed", forKey: .kind)
                try c.encode(h, forKey: .reasonHash)
            }
        }
    }

    public init(
        id: String = UUID().uuidString,
        text: String,
        attachmentIDs: [String] = [],
        queuedAt: Date = Date(),
        sequence: Int = 0,
        state: State = .pending
    ) {
        self.id = id
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.queuedAt = queuedAt
        self.sequence = sequence
        self.state = state
    }
}

// MARK: - Queue manipulation

extension Array where Element == QueuedTurn {
    /// Re-sequence so each item gets a strictly-increasing integer.
    public mutating func resequenced() {
        for index in self.indices {
            self[index].sequence = index
        }
    }

    /// The next pending item — the head of the queue.
    public var nextPending: QueuedTurn? {
        sorted { $0.sequence < $1.sequence }.first { $0.state == .pending }
    }
}
