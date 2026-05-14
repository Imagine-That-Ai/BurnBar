import Foundation
import Observation

/// Source of `AgentInsightsBundle`s for a particular platform.
///
/// Each platform shell implements its own producer that knows how to
/// reach its data source, canvas store, and audit log. The shared
/// `AgentInsightsBundleAssembler` then turns those inputs into a
/// uniform bundle. Keep producers tiny — they only wire data, not
/// render or filter.
public protocol AgentInsightsBundleProducer: AnyObject, Sendable {
    /// Produces a bundle for the given scope, or throws on failure.
    func bundle(for scope: AgentInsightsScope) async throws -> AgentInsightsBundle
}

/// Drives the per-agent Insights surface across all SwiftUI platforms.
///
/// View-owned with `@State` (iOS/iPad/macOS), or injected via `@Bindable`
/// when a parent owns the lifetime (e.g. iPad split view where the
/// sidebar selection mutates the scope without re-creating the model).
@MainActor
@Observable
public final class AgentInsightsViewModel {
    public private(set) var scope: AgentInsightsScope
    public private(set) var bundle: AgentInsightsBundle?
    public private(set) var loadState: LoadState = .idle
    public private(set) var errorMessage: String?

    private let producer: any AgentInsightsBundleProducer
    private var inflightTask: Task<Void, Never>?

    public init(scope: AgentInsightsScope, producer: any AgentInsightsBundleProducer) {
        self.scope = scope
        self.producer = producer
    }

    public func load() async {
        if loadState == .loading || loadState == .refreshing { return }
        await fetch()
    }

    public func refresh() async {
        if loadState == .refreshing { return }
        await fetch()
    }

    public func setScope(_ newScope: AgentInsightsScope) async {
        guard newScope != scope else { return }
        scope = newScope
        bundle = nil
        await fetch()
    }

    private func fetch() async {
        inflightTask?.cancel()
        let target = scope
        let task = Task { @MainActor in
            loadState = (bundle == nil ? .loading : .refreshing)
            errorMessage = nil
            do {
                let next = try await producer.bundle(for: target)
                if Task.isCancelled { return }
                // Drop the result if the scope changed under us.
                guard target == scope else { return }
                bundle = next
                loadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                loadState = bundle == nil ? .failed : .loaded
            }
        }
        inflightTask = task
        await task.value
    }

    public enum LoadState: String, Sendable, Equatable {
        case idle, loading, refreshing, loaded, failed
    }
}

// MARK: - Static producer (tests / previews)

/// Returns a pre-built bundle for every scope. Handy in tests and previews
/// where you don't want to construct a real data source.
public final class StaticAgentInsightsBundleProducer: AgentInsightsBundleProducer, @unchecked Sendable {
    private let provide: @Sendable (AgentInsightsScope) -> AgentInsightsBundle

    public init(_ provide: @escaping @Sendable (AgentInsightsScope) -> AgentInsightsBundle) {
        self.provide = provide
    }

    public func bundle(for scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
        provide(scope)
    }
}
