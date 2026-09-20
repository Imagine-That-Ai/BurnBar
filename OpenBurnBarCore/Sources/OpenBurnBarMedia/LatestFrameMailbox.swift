import Foundation

/// Single-slot coalescing mailbox: concurrent producers replace the pending
/// value; one pump Task drains it. Capture/encode callbacks must not spawn
/// an unbounded `Task` per frame.
public final class LatestFrameMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var pumping = false
    private let consume: @Sendable (Value) async -> Void

    public init(consume: @escaping @Sendable (Value) async -> Void) {
        self.consume = consume
    }

    public func submit(_ value: Value) {
        lock.lock()
        pending = value
        let startPump = !pumping
        if startPump {
            pumping = true
        }
        lock.unlock()
        if startPump {
            Task {
                await self.drain()
            }
        }
    }

    public var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    private func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let next = pending
        pending = nil
        if next == nil {
            pumping = false
        }
        return next
    }

    private func drain() async {
        while true {
            guard let next = take() else { return }
            await consume(next)
        }
    }
}
