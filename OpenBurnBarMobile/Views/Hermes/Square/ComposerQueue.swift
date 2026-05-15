import SwiftUI
import OpenBurnBarCore

// MARK: - Composer Queue (Hermes Square §6.8)
//
// Horizontal strip above the chat composer. Lets the user append
// follow-up turns while the agent is still working on the current turn.
// Source pattern: Replit Queue
// (https://blog.replit.com/introducing-queue-a-smarter-way-to-work-with-agent).

struct ComposerQueueStrip: View {
    @Binding var queue: [QueuedTurn]
    let onSendNext: (QueuedTurn) -> Void
    let onCancel: (QueuedTurn) -> Void

    var body: some View {
        if queue.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(queue.sorted { $0.sequence < $1.sequence }) { turn in
                        chip(for: turn)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(
                Rectangle()
                    .fill(DesignSystemColors.surface.opacity(0.4))
                    .overlay(
                        Rectangle()
                            .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                            .frame(height: 0.5)
                            .frame(maxHeight: .infinity, alignment: .top)
                    )
            )
        }
    }

    private func chip(for turn: QueuedTurn) -> some View {
        HStack(spacing: 6) {
            stateGlyph(for: turn.state)
            Text(truncate(turn.text, 24))
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !turn.attachmentIDs.isEmpty {
                Text("\(turn.attachmentIDs.count)📎")
                    .font(.caption2)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            if case .pending = turn.state {
                Button {
                    onCancel(turn)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(chipBackground(for: turn.state))
                .overlay(Capsule().stroke(chipBorder(for: turn.state), lineWidth: 0.5))
        )
    }

    @ViewBuilder
    private func stateGlyph(for state: QueuedTurn.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(DesignSystemColors.textMuted)
        case .inFlight:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(DesignSystemColors.success)
        case .cancelled:
            Image(systemName: "xmark").font(.caption2).foregroundStyle(DesignSystemColors.textMuted)
        case .failed:
            Image(systemName: "exclamationmark").font(.caption2).foregroundStyle(DesignSystemColors.error)
        }
    }

    private func chipBackground(for state: QueuedTurn.State) -> Color {
        switch state {
        case .pending:   return DesignSystemColors.surface
        case .inFlight:  return DesignSystemColors.ember.opacity(0.18)
        case .completed: return DesignSystemColors.success.opacity(0.10)
        case .cancelled: return DesignSystemColors.surface.opacity(0.4)
        case .failed:    return DesignSystemColors.error.opacity(0.10)
        }
    }

    private func chipBorder(for state: QueuedTurn.State) -> Color {
        switch state {
        case .pending:   return DesignSystemColors.borderSubtle
        case .inFlight:  return DesignSystemColors.ember.opacity(0.5)
        case .completed: return DesignSystemColors.success.opacity(0.5)
        case .cancelled: return DesignSystemColors.borderSubtle
        case .failed:    return DesignSystemColors.error.opacity(0.5)
        }
    }

    private func truncate(_ s: String, _ limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }
}

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
