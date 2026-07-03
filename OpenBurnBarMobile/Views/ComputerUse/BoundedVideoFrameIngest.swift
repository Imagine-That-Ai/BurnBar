#if canImport(UIKit)
import Foundation
import OpenBurnBarMedia

/// Serializes inbound mirror frames through a bounded stream so callers can
/// fire-and-forget without spawning one unstructured `Task` per frame.
@MainActor
final class BoundedVideoFrameIngest {
    private var continuation: AsyncStream<MediaFrame>.Continuation?
    private var consumerTask: Task<Void, Never>?

    func bind(consumer: @escaping @MainActor (MediaFrame) async -> Void) {
        cancel()
        let stream = AsyncStream<MediaFrame>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            self.continuation = continuation
        }
        consumerTask = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await consumer(frame)
            }
            await MainActor.run { self?.continuation = nil }
        }
    }

    func submit(_ frame: MediaFrame) {
        continuation?.yield(frame)
    }

    func cancel() {
        consumerTask?.cancel()
        consumerTask = nil
        continuation?.finish()
        continuation = nil
    }

    deinit {
        consumerTask?.cancel()
        continuation?.finish()
    }
}
#endif
