import Foundation

/// Orchestrates the two-tier verdict pipeline (plan §4.2).
///
/// Tier 1: read the cache and render immediately.
/// Tier 2: in the background, build a digest, run the rule-based engine,
/// optionally upgrade via an LLM author, validate with the voice
/// post-processor, and swap the result into the cache. Each step emits an
/// `Event` so the renderer can animate transitions in.
///
/// The composer never blocks the UI. Reads are bounded by the cache's
/// in-memory budget; refreshes happen on the calling task's executor.
public actor VerdictComposer {

    // MARK: - Dependencies

    /// The producer that builds the privacy-bounded digest for the window.
    /// Provided as a closure so the composer stays decoupled from the
    /// per-platform data sources.
    public typealias DigestProducer = @Sendable (VerdictWindow) async throws -> InsightDigest

    /// The LLM upgrade pass — optional. Receives the rule-based draft as
    /// the "prior" and returns a model-authored candidate to feed through
    /// the post-processor. Implementations are wired in the app shells
    /// (macOS, iOS, Android) where the model gateways live.
    public typealias LLMAuthor = @Sendable (
        InsightVerdict,        // rule-based draft
        InsightDigest          // the digest the draft was authored from
    ) async throws -> InsightVerdict?

    /// Citation validator the composer hands to the post-processor.
    public typealias CitationValidator = InsightVoicePostProcessor.CitationValidator

    private let cache: VerdictCache
    private let engine: RuleBasedVerdictEngine
    private let postProcessor: InsightVoicePostProcessor
    private let digestProducer: DigestProducer
    private let llmAuthor: LLMAuthor?
    private let citationValidatorFactory:
        @Sendable (InsightDigest) -> CitationValidator
    private let deviceID: String

    public init(
        deviceID: String,
        cache: VerdictCache,
        engine: RuleBasedVerdictEngine = RuleBasedVerdictEngine(),
        postProcessor: InsightVoicePostProcessor = InsightVoicePostProcessor(),
        digestProducer: @escaping DigestProducer,
        llmAuthor: LLMAuthor? = nil,
        citationValidatorFactory: @escaping @Sendable (InsightDigest) -> CitationValidator
            = VerdictComposer.defaultCitationValidator
    ) {
        self.deviceID = deviceID
        self.cache = cache
        self.engine = engine
        self.postProcessor = postProcessor
        self.digestProducer = digestProducer
        self.llmAuthor = llmAuthor
        self.citationValidatorFactory = citationValidatorFactory
    }

    // MARK: - Events

    public enum Event: Sendable {
        case cached(InsightVerdict, isStale: Bool)
        case demo(InsightVerdict)
        case ruleBasedUpgrade(InsightVerdict)
        case llmUpgrade(InsightVerdict, report: InsightVoicePostProcessor.Report)
        case llmRejected(reason: InsightVoicePostProcessor.RejectionReason)
        case failed(error: String)
    }

    // MARK: - Read-fast entry

    /// Returns the cached verdict (if any) plus its staleness for instant
    /// rendering. Does not touch the network/disk beyond hydration.
    public func instant(window: VerdictWindow, now: Date = Date()) async -> VerdictCache.Read? {
        if let read = await cache.read(window: window, deviceID: deviceID, now: now) {
            return read
        }
        return await cache.readMostRecent(window: window, deviceID: deviceID, now: now)
    }

    // MARK: - Refresh

    /// Refreshes the cache for the window and streams events as new
    /// candidates land. The stream finishes after the LLM upgrade (or
    /// after the rule-based draft if no LLM author is configured).
    public func refresh(
        window: VerdictWindow,
        now: Date = Date()
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task { [self] in
                // Step 1 — emit current cached value if present.
                if let cached = await instant(window: window, now: now) {
                    continuation.yield(.cached(cached.verdict, isStale: cached.isStale))
                }
                // Step 2 — build digest + rule-based draft.
                let digest: InsightDigest
                do {
                    digest = try await digestProducer(window)
                } catch {
                    continuation.yield(.failed(error: String(describing: error)))
                    continuation.finish()
                    return
                }
                let priorDigest: InsightDigest? = nil // future: wire prior-window producer
                let draft = engine.produce(
                    digest: digest,
                    window: window,
                    priorDigest: priorDigest,
                    now: now
                )
                await cache.write(draft, deviceID: deviceID, now: now)
                continuation.yield(.ruleBasedUpgrade(draft))

                // Step 3 — optional LLM upgrade.
                if let author = llmAuthor {
                    do {
                        guard let candidate = try await author(draft, digest) else {
                            continuation.finish()
                            return
                        }
                        let validator = citationValidatorFactory(digest)
                        switch postProcessor.process(candidate, citationValidator: validator) {
                        case .accepted(let cleaned, let report):
                            await cache.write(cleaned, deviceID: deviceID, now: now)
                            continuation.yield(.llmUpgrade(cleaned, report: report))
                        case .rejected(let reason, _):
                            continuation.yield(.llmRejected(reason: reason))
                        }
                    } catch {
                        continuation.yield(.failed(error: String(describing: error)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - First-run helpers

    /// Write the demo fixture into the cache for the window so the first
    /// open of a brand-new install never sees a placeholder.
    public func seedDemoIfEmpty(
        window: VerdictWindow,
        anchor: Date = Date()
    ) async {
        if await cache.count(deviceID: deviceID, window: window) > 0 { return }
        let fixture = InsightVerdictDemoFixture.sample(window: window, anchored: anchor)
        await cache.write(fixture, deviceID: deviceID, now: anchor)
    }

    // MARK: - Defaults

    public static let defaultCitationValidator:
        @Sendable (InsightDigest) -> InsightVoicePostProcessor.CitationValidator = { digest in
        let providerKeys = Set(digest.providers.map(\.id))
        let modelIDs = Set(digest.models.map(\.id))
        let projectNames = Set(digest.projects.map(\.displayName))
        let actionIDs = Set(digest.operatingActions.map(\.id))
        let anomalyIDs = Set(digest.anomalies.map(\.id))
        return { citation in
            switch citation.kind {
            case .session(let id, _):
                // Sessions in the digest are referenced by ActionDigest IDs.
                return actionIDs.contains(id) || !id.isEmpty
            case .model(let id):
                return modelIDs.contains(id)
            case .agent(let provider):
                return providerKeys.contains(provider) || provider == "all"
            case .project(let name):
                return projectNames.contains(name) || !name.isEmpty
            case .day(let date):
                return !date.isEmpty
            case .anomaly(let id):
                return anomalyIDs.contains(id)
            case .query:
                return true
            case .quota(let provider, _):
                return providerKeys.contains(provider)
            case .benchmark:
                return true
            }
        }
    }
}
