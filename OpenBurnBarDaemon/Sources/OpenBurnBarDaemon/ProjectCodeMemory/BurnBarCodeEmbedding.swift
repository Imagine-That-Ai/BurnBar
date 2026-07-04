import Foundation
@preconcurrency import NaturalLanguage

/// A daemon-owned text embedder for code chunks. The default implementation uses the
/// OS-provided NaturalLanguage sentence embedding, so the daemon needs no bundled model
/// and code memory works fully on its own — even with the app closed. A better /
/// code-specialised model can be dropped in behind this protocol without touching the
/// store: only `versionID`/`dimension`/`embed` matter.
protocol BurnBarCodeEmbeddingProvider: Sendable {
    /// Identifies the generation that produced a vector. Stored alongside every vector
    /// so search never compares across generations (the §5.9 version floor) and a
    /// version bump re-embeds on the next index.
    var versionID: String { get }
    /// Vector length. 0 means "embeddings unavailable" (the provider degrades to lexical).
    var dimension: Int { get }
    /// Embed `text`, or nil when the text is empty or the model declines it.
    func embed(_ text: String) -> [Float]?
}

extension BurnBarCodeEmbeddingProvider {
    var isAvailable: Bool { dimension > 0 }
}

/// Default daemon embedder: Apple's built-in NaturalLanguage sentence embedding. No model
/// file is shipped — it is part of the OS — and it runs in-process. Quality is general-NL
/// (good on identifiers/comments/doc text); the protocol boundary keeps future
/// code-specialised providers isolated to versioned embedding generation.
struct NLSentenceEmbeddingProvider: BurnBarCodeEmbeddingProvider {
    let versionID: String
    let dimension: Int

    init() {
        // Only the (Sendable) dimension/version are stored. The NLEmbedding model itself
        // is non-Sendable and OS-cached, so it is looked up per call rather than held.
        let dim = NLEmbedding.sentenceEmbedding(for: .english)?.dimension ?? 0
        dimension = dim
        // The dimension is part of the version so a model swap that changes the vector
        // length can never be silently compared against old vectors.
        versionID = "nl-sentence-en-\(dim)"
    }

    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let model = NLEmbedding.sentenceEmbedding(for: .english),
              let vector = model.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }
}

// MARK: - Ollama dense-tier provider (ADR-012, loopback-only)

/// Optional dense embedder backed by a local `ollama serve` instance.
/// Selected when `OPENBURNBAR_OLLAMA_EMBED_URL` points at loopback (default http://127.0.0.1:11434).
struct OllamaSentenceEmbeddingProvider: BurnBarCodeEmbeddingProvider, @unchecked Sendable {
    let versionID: String
    let dimension: Int
    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["OPENBURNBAR_OLLAMA_EMBED_URL"] != nil else { return nil }
        let urlString = environment["OPENBURNBAR_OLLAMA_EMBED_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "http://127.0.0.1:11434"
        let model = environment["OPENBURNBAR_OLLAMA_EMBED_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "nomic-embed-text"
        guard let url = URL(string: urlString),
              let client = try? BurnBarOllamaEmbeddingClient(baseURL: url, model: model) else { return nil }
        baseURL = client.baseURL
        self.model = client.model
        session = client.session
        timeout = client.timeout
        guard let probe = Self.embedSync(text: "openburnbar pcm embedding probe", baseURL: baseURL, model: model, session: session, timeout: timeout) else {
            return nil
        }
        dimension = probe.count
        versionID = "ollama-\(model)-\(probe.count)"
    }

    func embed(_ text: String) -> [Float]? {
        Self.embedSync(text: text, baseURL: baseURL, model: model, session: session, timeout: timeout)
    }

    private static func embedSync(
        text: String,
        baseURL: URL,
        model: String,
        session: URLSession,
        timeout: TimeInterval
    ) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["model": model, "input": [trimmed]]) else { return nil }
        request.httpBody = body
        var payload: Data?
        var http: HTTPURLResponse?
        var requestError: Error?
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            payload = data
            http = response as? HTTPURLResponse
            requestError = error
            sem.signal()
        }.resume()
        sem.wait()
        if requestError != nil { return nil }
        guard let http, (200..<300).contains(http.statusCode), let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let matrix = json["embeddings"] as? [[NSNumber]] {
            return matrix.first?.map { Float(truncating: $0) }
        }
        if let single = json["embedding"] as? [NSNumber] {
            return single.map { Float(truncating: $0) }
        }
        return nil
    }
}

enum BurnBarCodeEmbeddingProviderFactory {
    /// Prefer loopback Ollama when configured and reachable; otherwise OS NaturalLanguage.
    static func makeDefault() -> BurnBarCodeEmbeddingProvider {
        if let ollama = OllamaSentenceEmbeddingProvider() {
            return ollama
        }
        return NLSentenceEmbeddingProvider()
    }
}

/// Compact, alignment-safe float32 (little-endian) blob codec + cosine for stored vectors.
enum BurnBarCodeVectorCodec {
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    static func base64EncodedByteCount(vectorDimension: Int) -> Int {
        guard vectorDimension > 0 else { return 0 }
        let rawBytes = vectorDimension * MemoryLayout<Float>.size
        return ((rawBytes + 2) / 3) * 4
    }

    static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension > 0, data.count == dimension * MemoryLayout<Float>.size else { return nil }
        var out = [Float](repeating: 0, count: dimension)
        let copied = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return copied == data.count ? out : nil
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return -1 }
        var dot = 0.0
        var normL = 0.0
        var normR = 0.0
        for index in 0..<lhs.count {
            let x = Double(lhs[index])
            let y = Double(rhs[index])
            dot += x * y
            normL += x * x
            normR += y * y
        }
        let denom = normL.squareRoot() * normR.squareRoot()
        return denom > 0 ? dot / denom : -1
    }
}

/// Reciprocal Rank Fusion (k = 60). Fuses several ranked id-lists into one ranking without
/// needing comparable per-list scores — the standard way to blend lexical (BM25) and
/// semantic (cosine) results. Higher fused score ranks first; ties break by id for
/// determinism.
enum BurnBarReciprocalRankFusion {
    static func fuse(_ rankedLists: [[String]], k: Double = 60) -> [String] {
        var scores: [String: Double] = [:]
        for list in rankedLists {
            for (zeroBasedRank, id) in list.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(zeroBasedRank + 1))
            }
        }
        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { $0.key }
    }
}

// MARK: - Ollama dense-tier client (ADR-012, loopback-only)

enum BurnBarOllamaEmbeddingError: Error, LocalizedError {
    case nonLoopbackHost(String)
    case invalidResponse
    case httpStatus(Int)
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .nonLoopbackHost(let host): return "Ollama host must be loopback-only; got \(host)."
        case .invalidResponse: return "Ollama embedding response was not valid JSON."
        case .httpStatus(let code): return "Ollama embedding request failed with HTTP \(code)."
        case .emptyInput: return "Ollama embedding input was empty."
        }
    }
}

struct BurnBarOllamaEmbeddingClient: Sendable {
    let baseURL: URL
    let model: String
    let session: URLSession
    let timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = "nomic-embed-text",
        session: URLSession = .shared,
        timeout: TimeInterval = 30
    ) throws {
        try Self.assertLoopbackOnly(baseURL)
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ $0.isEmpty == false }) else { throw BurnBarOllamaEmbeddingError.emptyInput }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": trimmed
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BurnBarOllamaEmbeddingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw BurnBarOllamaEmbeddingError.httpStatus(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BurnBarOllamaEmbeddingError.invalidResponse
        }
        if let matrix = json["embeddings"] as? [[NSNumber]] {
            return matrix.map { $0.map { Float(truncating: $0) } }
        }
        if let single = json["embedding"] as? [NSNumber] {
            return [single.map { Float(truncating: $0) }]
        }
        throw BurnBarOllamaEmbeddingError.invalidResponse
    }

    static func assertLoopbackOnly(_ url: URL) throws {
        guard let host = url.host?.lowercased() else {
            throw BurnBarOllamaEmbeddingError.nonLoopbackHost("missing-host")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw BurnBarOllamaEmbeddingError.nonLoopbackHost(host)
        }
    }
}
