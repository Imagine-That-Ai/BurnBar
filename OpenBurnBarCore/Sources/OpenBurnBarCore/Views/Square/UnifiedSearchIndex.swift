import Foundation

// MARK: - Unified Search Index (Hermes Square §6.2)
//
// Federated search across the six corpuses listed in plan §3:
//   • agents       — `AgentIdentity` records (built-in + installed)
//   • threads      — `ThreadInboxItem` rows
//   • missions     — `MissionConsoleActiveTile` rows (live) + historical
//   • artifacts    — files / images / charts emitted by past missions
//   • cards        — `CardEnvelope` rows persisted in the thread store
//   • web          — gated; only when a remote search endpoint is wired
//
// Pure Swift, no Firebase, no UI dependencies. Single-threaded actor
// guards mutation; queries fan out concurrently across corpuses.
//
// Indexing strategy:
//   • Per-document token list (lowercased, ascii-folded, simple split on
//     non-alphanumerics). No stemming — too aggressive for code search,
//     where we care about `dispatchFanOut` vs `dispatched` distinction.
//   • Per-token inverted index: `[String: [DocumentRef]]`.
//   • Per-document recency: `[DocumentRef: Date]`. Used in scoring.
//
// Score = (Σ token matches) × recency boost where recency boost ∈ [0.7,
// 1.2] over a 30-day window.

public actor UnifiedSearchIndex {

    // MARK: Corpus

    public enum Corpus: String, CaseIterable, Sendable, Hashable, Codable {
        case agents
        case threads
        case missions
        case artifacts
        case cards
        case web
    }

    // MARK: Document ref

    public struct DocumentRef: Sendable, Hashable, Codable {
        public let corpus: Corpus
        public let id: String

        public init(corpus: Corpus, id: String) {
            self.corpus = corpus
            self.id = id
        }
    }

    // MARK: Hit

    public struct Hit: Sendable, Hashable {
        public let ref: DocumentRef
        public let title: String
        public let preview: String
        public let score: Double
        public let lastActivityAt: Date?

        public init(
            ref: DocumentRef,
            title: String,
            preview: String,
            score: Double,
            lastActivityAt: Date? = nil
        ) {
            self.ref = ref
            self.title = title
            self.preview = preview
            self.score = score
            self.lastActivityAt = lastActivityAt
        }
    }

    public struct Document: Sendable, Hashable {
        public let ref: DocumentRef
        public let title: String
        public let body: String
        public let lastActivityAt: Date?
        public let preview: String

        public init(
            ref: DocumentRef,
            title: String,
            body: String,
            lastActivityAt: Date? = nil,
            preview: String? = nil
        ) {
            self.ref = ref
            self.title = title
            self.body = body
            self.lastActivityAt = lastActivityAt
            // Use first 120 chars of body if no preview supplied.
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let computed = preview ?? String(trimmed.prefix(120))
            self.preview = computed
        }
    }

    // MARK: State

    private var inverted: [String: Set<DocumentRef>] = [:]
    private var documents: [DocumentRef: Document] = [:]

    public init() {}

    // MARK: Mutation

    public func upsert(_ doc: Document) {
        // Drop prior tokens if the doc was already indexed.
        if let prior = documents[doc.ref] {
            for token in Self.tokenize(prior.title + " " + prior.body) {
                inverted[token]?.remove(prior.ref)
                if inverted[token]?.isEmpty == true {
                    inverted.removeValue(forKey: token)
                }
            }
        }
        documents[doc.ref] = doc
        for token in Self.tokenize(doc.title + " " + doc.body) {
            inverted[token, default: []].insert(doc.ref)
        }
    }

    public func remove(_ ref: DocumentRef) {
        guard let doc = documents[ref] else { return }
        for token in Self.tokenize(doc.title + " " + doc.body) {
            inverted[token]?.remove(ref)
            if inverted[token]?.isEmpty == true {
                inverted.removeValue(forKey: token)
            }
        }
        documents.removeValue(forKey: ref)
    }

    public func clear(corpus: Corpus? = nil) {
        if let corpus {
            for ref in documents.keys where ref.corpus == corpus {
                remove(ref)
            }
        } else {
            inverted.removeAll()
            documents.removeAll()
        }
    }

    public var documentCount: Int { documents.count }

    // MARK: Query

    public struct QueryOptions: Sendable {
        public var corpuses: Set<Corpus>
        public var limitPerCorpus: Int
        public var now: Date

        public init(
            corpuses: Set<Corpus> = Set(Corpus.allCases),
            limitPerCorpus: Int = 8,
            now: Date = Date()
        ) {
            self.corpuses = corpuses
            self.limitPerCorpus = limitPerCorpus
            self.now = now
        }

        public static let `default` = QueryOptions()
    }

    /// Run a query. Returns a per-corpus dict of ranked hits.
    public func search(_ raw: String, options: QueryOptions = .default) -> [Corpus: [Hit]] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [:] }
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return [:] }

        // Per-doc score = number of unique matching tokens × recency boost.
        var scores: [DocumentRef: Int] = [:]
        for token in tokens {
            // Exact match first.
            if let exact = inverted[token] {
                for ref in exact { scores[ref, default: 0] += 2 }
            }
            // Prefix match (cheap fan-out for autocomplete).
            for (key, refs) in inverted where key.count > token.count && key.hasPrefix(token) {
                for ref in refs { scores[ref, default: 0] += 1 }
            }
        }

        // Group by corpus, apply recency, sort.
        var perCorpus: [Corpus: [Hit]] = [:]
        for (ref, base) in scores {
            guard options.corpuses.contains(ref.corpus) else { continue }
            guard let doc = documents[ref] else { continue }
            let recencyBoost = recencyBoost(for: doc.lastActivityAt, now: options.now)
            let final = Double(base) * recencyBoost
            let hit = Hit(
                ref: ref,
                title: doc.title,
                preview: doc.preview,
                score: final,
                lastActivityAt: doc.lastActivityAt
            )
            perCorpus[ref.corpus, default: []].append(hit)
        }
        for corpus in perCorpus.keys {
            perCorpus[corpus]?.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let l = lhs.lastActivityAt ?? .distantPast
                let r = rhs.lastActivityAt ?? .distantPast
                return l > r
            }
            perCorpus[corpus] = Array(perCorpus[corpus]?.prefix(options.limitPerCorpus) ?? [])
        }
        return perCorpus
    }

    /// Flat ranked list across all corpuses. Use for the "best 5" header
    /// row in the search drawer.
    public func searchFlat(_ raw: String, limit: Int = 10, options: QueryOptions = .default) -> [Hit] {
        let perCorpus = search(raw, options: options)
        var flat = perCorpus.values.flatMap { $0 }
        flat.sort { $0.score > $1.score }
        return Array(flat.prefix(limit))
    }

    // MARK: Token helpers

    /// Lowercase, fold diacritics, split on non-alphanumerics. Keep tokens
    /// ≥ 2 chars.
    public static func tokenize(_ s: String) -> [String] {
        let folded = s.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var tokens: [String] = []
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if current.count >= 2 { tokens.append(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 2 { tokens.append(current) }
        return tokens
    }

    // MARK: Recency

    private func recencyBoost(for date: Date?, now: Date) -> Double {
        guard let date else { return 0.85 }
        let age = now.timeIntervalSince(date)
        if age < 0 { return 1.20 }
        let day: TimeInterval = 86_400
        if age < day { return 1.20 }
        if age < 7 * day { return 1.05 }
        if age < 30 * day { return 0.95 }
        return 0.70
    }
}

// MARK: - Document builders (corpus-specific helpers)

extension UnifiedSearchIndex.Document {
    /// Build a document from an `AgentIdentity`.
    public static func from(_ identity: AgentIdentity) -> UnifiedSearchIndex.Document {
        let body = [
            identity.displayName,
            identity.tagline ?? "",
            identity.capabilities.displayPills.joined(separator: " "),
            identity.tier.displayLabel,
            identity.runtimeID?.rawValue ?? ""
        ].joined(separator: " ")
        return UnifiedSearchIndex.Document(
            ref: UnifiedSearchIndex.DocumentRef(corpus: .agents, id: identity.id),
            title: identity.displayName,
            body: body,
            lastActivityAt: identity.lastRefreshedAt,
            preview: identity.tagline ?? identity.displayName
        )
    }

    /// Build a document from a `ThreadInboxItem`.
    public static func from(_ item: ThreadInboxItem) -> UnifiedSearchIndex.Document {
        let body = [item.title, item.preview, item.agentURI].joined(separator: " ")
        return UnifiedSearchIndex.Document(
            ref: UnifiedSearchIndex.DocumentRef(corpus: .threads, id: item.id),
            title: item.title,
            body: body,
            lastActivityAt: item.lastActivityAt,
            preview: item.preview
        )
    }

    /// Build a document from a `MissionConsoleActiveTile`.
    public static func from(_ tile: MissionConsoleActiveTile) -> UnifiedSearchIndex.Document {
        let body = [
            tile.title,
            tile.phaseDetail ?? "",
            tile.currentToolName ?? "",
            tile.lastEventSnippet ?? "",
            tile.runtimeDisplayLabel
        ].joined(separator: " ")
        return UnifiedSearchIndex.Document(
            ref: UnifiedSearchIndex.DocumentRef(corpus: .missions, id: tile.id),
            title: tile.title,
            body: body,
            lastActivityAt: tile.startedAt,
            preview: tile.phaseDetail ?? tile.runtimeDisplayLabel
        )
    }

    /// Build a document from a `CardEnvelope` (best-effort).
    public static func from(_ envelope: CardEnvelope, contextID: String) -> UnifiedSearchIndex.Document {
        let title: String
        let body: String
        switch envelope {
        case .text(let p):
            title = String(p.markdown.prefix(64))
            body  = p.markdown + " " + (p.footnote ?? "")
        case .table(let p):
            title = p.caption ?? "Table"
            body  = (p.headers + p.rows.flatMap { $0 }).joined(separator: " ")
        case .diff(let p):
            title = p.file
            body  = p.file + " " + p.before + " " + p.after
        case .image(let p):
            title = p.alt
            body  = p.alt
        case .chart(let p):
            title = "Chart"
            body  = p.spec
        case .approval(let p):
            title = p.prompt
            body  = p.prompt + " " + (p.detail ?? "")
        case .mission(let p):
            title = "Mission \(p.missionID)"
            body  = p.missionID
        case .custom(let p):
            title = "Mini-program"
            body  = p.schemaURL + " " + p.sandboxURL
        case .tooLarge(let p):
            title = "Too-large card"
            body  = p.kindAttempted
        case .unknown(let s):
            title = "Unknown card"
            body  = s
        }
        return UnifiedSearchIndex.Document(
            ref: UnifiedSearchIndex.DocumentRef(corpus: .cards, id: contextID),
            title: title,
            body: body,
            lastActivityAt: Date(),
            preview: title
        )
    }
}
