import SwiftUI
import OpenBurnBarCore

// MARK: - Composer Queue (Hermes Square §6.8)
//
// Horizontal strip above the chat composer. Lets the user append
// follow-up turns while the agent is still working on the current turn.
// Source pattern: Replit Queue
// (https://blog.replit.com/introducing-queue-a-smarter-way-to-work-with-agent).

// MARK: - Queue controller

@MainActor
@Observable
final class ComposerQueueController {
    private(set) var queue: [QueuedTurn] = []

    /// Append a new pending turn at the end.
    func enqueue(text: String, attachmentIDs: [String] = []) {
        var newTurn = QueuedTurn(
            text: text,
            attachmentIDs: attachmentIDs,
            sequence: queue.count
        )
        newTurn.sequence = queue.count
        queue.append(newTurn)
        queue.resequenced()
    }

    /// Pop the next pending and mark it inFlight. Returns the turn to
    /// dispatch, or nil if the queue is empty.
    @discardableResult
    func startNext() -> QueuedTurn? {
        guard let idx = queue.firstIndex(where: { $0.state == .pending }) else { return nil }
        queue[idx].state = .inFlight
        return queue[idx]
    }

    func markCompleted(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].state = .completed
    }

    func markFailed(id: String, reasonHash: Int = 0) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].state = .failed(reasonHash: reasonHash)
    }

    func cancel(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[idx].state == .pending {
            queue.remove(at: idx)
            queue.resequenced()
        } else {
            queue[idx].state = .cancelled
        }
    }

    /// Clear all terminal items so the strip stays tight.
    func reapTerminal() {
        queue.removeAll { $0.state.isTerminal }
        queue.resequenced()
    }
}
