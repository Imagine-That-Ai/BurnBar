import Foundation
import OpenBurnBarInsights

/// Builds a month's recap, deterministically first and editorially second.
///
/// Two tiers, the shape `VerdictComposer` already established here: the
/// rule-built deck is complete on its own and is emitted immediately, then an
/// optional model pass rewrites only the prose and is emitted as a second event.
/// Nothing ever waits on a network call to show something real.
public actor RecapComposer {

    // MARK: - Events

    public enum Event: Sendable {
        /// The rule-built deck. Always arrives, always shippable.
        case deterministic(MonthlyRecap)
        /// The same deck with model-written prose. May never arrive.
        case voiced(MonthlyRecap)
        /// The month exists but is too thin to recap honestly.
        case notEnoughData(RecapWindow)
        /// Something went wrong reading the month.
        case failed(String)
    }

    // MARK: - Dependencies

    private let source: any RecapSource
    private let historyStore: RecapHistoryStore
    private let recapStore: RecapStore
    private let author: any RecapVoiceAuthor
    private let postProcessor: RecapVoicePostProcessor
    private let limits: RecapRanker.Limits
    private let calendar: Calendar
    private let historyDepth: Int

    public init(
        source: any RecapSource,
        historyStore: RecapHistoryStore,
        recapStore: RecapStore,
        author: any RecapVoiceAuthor = RecapVoiceAuthorUnavailable(),
        postProcessor: RecapVoicePostProcessor = RecapVoicePostProcessor(),
        limits: RecapRanker.Limits = .standard,
        calendar: Calendar = .current,
        historyDepth: Int = 12
    ) {
        self.source = source
        self.historyStore = historyStore
        self.recapStore = recapStore
        self.author = author
        self.postProcessor = postProcessor
        self.limits = limits
        self.calendar = calendar
        self.historyDepth = historyDepth
    }

    // MARK: - Reads

    /// A stored deck, with no fetching. Lets a view paint instantly on open.
    public func stored(for window: RecapWindow) async -> MonthlyRecap? {
        await recapStore.recap(for: window)
    }

    // MARK: - Build

    /// Builds `window`, emitting the deterministic deck and then, if a voice
    /// author is configured and the month accepts it, the edited one.
    public func build(
        window: RecapWindow,
        now: Date = Date(),
        forceRegenerate: Bool = false
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.run(
                    window: window,
                    now: now,
                    forceRegenerate: forceRegenerate,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        window: RecapWindow,
        now: Date,
        forceRegenerate: Bool,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        // A sealed month is answered from the store. The single exception is a
        // month sealed without prose when an author is now available — the
        // one-time upgrade that keeps the AI toggle from looking broken.
        if !forceRegenerate, let existing = await recapStore.recap(for: window) {
            continuation.yield(.deterministic(existing))
            // A preview describes a month still in progress, so a stored one is
            // stale the moment anything else happens that day. `.unsealed` is the
            // same problem with a worse ending: the month is over but sealing was
            // interrupted, and answering from the store means it never finishes
            // (Codex P1). Paint either for instant feedback, then rebuild. Only a
            // genuinely sealed month short-circuits.
            if !existing.sealState.isSealed {
                // fall through to the rebuild below
            } else {
                guard existing.sealState == .sealedWithoutVoice,
                      !(author is RecapVoiceAuthorUnavailable) else { return }
                if let upgraded = await voiceUpgrade(for: existing, window: window, now: now) {
                    continuation.yield(.voiced(upgraded))
                }
                return
            }
        }

        let facts: RecapFacts
        do {
            facts = try await loadFacts(window: window, now: now)
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            return
        }

        guard facts.meetsMinimumSubstance else {
            continuation.yield(.notEnoughData(window))
            return
        }

        // Every stored month, not just `historyDepth`: records claim "ever", and
        // a context that only saw the last twelve months would call a mediocre
        // month a lifetime best. `historyDepth` bounds what we *fetch*, not what
        // we compare against.
        let history = await historyStore.allFacts().filter { $0.window < window }
        let context = RecapContext(facts: facts, history: history, calendar: calendar)
        let candidates = RecapCandidateGenerator.candidates(for: context)
        let cards = RecapRanker.rank(candidates: candidates, limits: limits)

        guard !cards.isEmpty else {
            continuation.yield(.notEnoughData(window))
            return
        }

        let monthEnded = window.hasEnded(asOf: now, calendar: calendar)
        let deterministic = MonthlyRecap(
            window: window,
            generatedAt: now,
            title: RecapDeterministicVoice.title(for: context, cards: cards),
            subtitle: nil,
            cards: cards,
            closingSentence: RecapDeterministicVoice.closing(for: context, cards: cards),
            provenance: nil,
            isVoiceAuthored: false,
            isPartial: facts.isPartial,
            // Not sealed yet even for a finished month: the voice pass below
            // still gets its turn, and sealing before it would lock in prose
            // the user was about to get a better version of.
            sealState: monthEnded ? .unsealed : .preview
        )
        try? await recapStore.save(deterministic)
        continuation.yield(.deterministic(deterministic))

        guard !Task.isCancelled else { return }

        let voiced = await applyVoice(
            to: deterministic,
            context: context,
            candidates: candidates,
            monthEnded: monthEnded
        )

        if let voiced {
            try? await recapStore.save(voiced)
            continuation.yield(.voiced(voiced))
        } else if monthEnded {
            // The pass ran and produced nothing usable — that is a decision, so
            // the month seals on the deterministic copy.
            let sealed = deterministic.sealed(as: .sealedWithoutVoice)
            try? await recapStore.save(sealed)
            continuation.yield(.deterministic(sealed))
        }
    }

    // MARK: - Voice

    private func applyVoice(
        to recap: MonthlyRecap,
        context: RecapContext,
        candidates: [RecapCandidate],
        monthEnded: Bool
    ) async -> MonthlyRecap? {
        guard !(author is RecapVoiceAuthorUnavailable) else { return nil }

        // Only candidates that made the deck are offered — the model cannot
        // resurrect something the ranker excluded.
        let deckIDs = Set(recap.cards.map(\.id))
        let offered = candidates.filter { deckIDs.contains($0.id) }
        guard !offered.isEmpty else { return nil }

        let (payload, mapping) = RecapPromptPayload.build(context: context, candidates: offered)
        let request = RecapVoiceRequest.forPayload(payload)

        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            let outbound = attempt == 0 ? request : request.jsonOnlyRetry
            guard let response = try? await author.author(outbound) else { return nil }
            guard let parsed = ModelResponseJSON.decode(RecapVoiceResponse.self, from: response.text) else {
                continue
            }
            let processed = postProcessor.process(
                response: parsed,
                deterministicCards: recap.cards,
                fallbackTitle: recap.title,
                fallbackClosing: recap.closingSentence,
                mapping: mapping
            )
            switch processed {
            case let .accepted(outcome, _):
                return recap.withVoice(
                    title: outcome.title,
                    subtitle: outcome.subtitle,
                    closingSentence: outcome.closingSentence,
                    cards: outcome.cards,
                    provenance: response.modelTag,
                    sealState: monthEnded ? .sealed : .preview
                )
            case .rejected:
                continue
            }
        }
        return nil
    }

    /// The one-time re-author of a month that sealed without prose.
    private func voiceUpgrade(
        for recap: MonthlyRecap,
        window: RecapWindow,
        now: Date
    ) async -> MonthlyRecap? {
        guard let facts = await historyStore.facts(for: window) else { return nil }
        let history = await historyStore.allFacts().filter { $0.window < window }
        let context = RecapContext(facts: facts, history: history, calendar: calendar)
        let candidates = RecapCandidateGenerator.candidates(for: context)

        guard let voiced = await applyVoice(
            to: recap, context: context, candidates: candidates, monthEnded: true
        ) else { return nil }

        let outcome = try? await recapStore.save(voiced)
        return outcome == .storedAsVoiceUpgrade ? voiced : nil
    }

    // MARK: - History

    /// Reads the target month, filling any gaps in stored history at the same
    /// time so comparisons have something to stand on.
    ///
    /// The target month rides along in the **same** bulk request as the
    /// backfill. A database-backed source answers that with one covering scan;
    /// fetching history and then the month separately would scan `conversations`
    /// — which has no time index — twice on a first open.
    private func loadFacts(window: RecapWindow, now: Date) async throws -> RecapFacts {
        let missing = await historyStore.monthsNeedingBackfill(
            endingAt: window, monthsBack: historyDepth
        )
        guard !missing.isEmpty else {
            let facts = RecapFacts.build(
                batch: try await source.rows(for: window), builtAt: now, calendar: calendar
            )
            try? await historyStore.upsert(facts)
            return facts
        }

        let batches = try await source.rows(for: missing + [window])
        guard let target = batches[window] else {
            // The bulk path did not answer for the target; ask for it directly
            // rather than reporting a month we never read.
            let facts = RecapFacts.build(
                batch: try await source.rows(for: window), builtAt: now, calendar: calendar
            )
            try? await historyStore.upsert(facts)
            return facts
        }

        let historyStamp = window.end(calendar: calendar)
        var folded = missing.compactMap { month -> RecapFacts? in
            guard let batch = batches[month] else { return nil }
            return RecapFacts.build(batch: batch, builtAt: historyStamp, calendar: calendar)
        }
        let facts = RecapFacts.build(batch: target, builtAt: now, calendar: calendar)
        folded.append(facts)
        try? await historyStore.upsert(folded)
        return facts
    }
}
