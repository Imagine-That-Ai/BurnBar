import Foundation

/// Main-actor FIFO that deduplicates work until each element finishes.
@MainActor
final class SerialAsyncWorkQueue<Element, ID: Hashable> {
    typealias Handler = @MainActor (Element) async -> Void

    private let identifier: (Element) -> ID
    private var handler: Handler?
    private var processingTask: Task<Void, Never>?
    private var pending: [(id: ID, element: Element)] = []
    private var pendingIndex = 0
    private var scheduledIDs = Set<ID>()
    private var generation: UInt = 0

    init(identifier: @escaping (Element) -> ID) {
        self.identifier = identifier
    }

    func start(handler: @escaping Handler) {
        guard self.handler == nil else { return }
        self.handler = handler
        startProcessingIfNeeded()
    }

    func enqueue(_ elements: [Element]) {
        guard handler != nil else { return }
        for element in elements {
            let id = identifier(element)
            if scheduledIDs.insert(id).inserted {
                pending.append((id, element))
            }
        }
        startProcessingIfNeeded()
    }

    func stop() {
        generation &+= 1
        processingTask?.cancel()
        handler = nil
        pending.removeAll(keepingCapacity: true)
        pendingIndex = 0
        scheduledIDs.removeAll(keepingCapacity: true)
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil, handler != nil, pendingIndex < pending.count else { return }
        let generation = generation
        processingTask = Task { @MainActor [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: UInt) async {
        guard generation == self.generation, let handler else {
            finishProcessing(generation: generation)
            return
        }
        while generation == self.generation, !Task.isCancelled, pendingIndex < pending.count {
            let work = pending[pendingIndex]
            pendingIndex += 1
            await handler(work.element)
            if generation == self.generation {
                scheduledIDs.remove(work.id)
            }
        }
        finishProcessing(generation: generation)
    }

    private func finishProcessing(generation: UInt) {
        if generation == self.generation, pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        }
        processingTask = nil
        startProcessingIfNeeded()
    }
}
