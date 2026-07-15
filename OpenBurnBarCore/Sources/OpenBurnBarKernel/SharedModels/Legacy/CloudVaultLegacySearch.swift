import Foundation

enum CloudVaultLegacySearch {
    private struct SemanticFeature {
        let name: String
        let weight: Double
    }

    private static let searchStopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
        "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
        "into", "onto", "can", "could", "should", "would"
    ]

    static func tokenHashes(for text: String, keyData: Data, limit: Int) throws -> [String] {
        let key = try searchKey(from: keyData)
        return tokenHashes(forTerms: normalizedTokens(from: text), key: key, limit: limit)
    }

    static func searchIndexTokenHashes(for text: String, keyData: Data, limit: Int) throws -> [String] {
        let key = try searchKey(from: keyData)
        let tokens = uniqueNormalizedTokens(from: text)
        var terms = tokens
        terms.append(contentsOf: searchIndexPrefixTerms(from: tokens))
        terms.append(contentsOf: exactPhraseTerms(from: text))
        return tokenHashes(forTerms: terms, key: key, limit: limit)
    }

    static func searchQueryTokenHashes(for text: String, keyData: Data, limit: Int) throws -> [String] {
        let key = try searchKey(from: keyData)
        let tokens = uniqueNormalizedTokens(from: text)
        var terms = tokens
        terms.append(contentsOf: tokens.compactMap(searchQueryPrefixTerm))
        terms.append(contentsOf: exactPhraseTerms(from: text))
        return tokenHashes(forTerms: terms, key: key, limit: limit)
    }

    static func semanticHashes(for text: String, keyData: Data, limit: Int) throws -> [String] {
        let tokens = exactPhraseTokens(from: text)
        guard tokens.isEmpty == false, limit > 0 else { return [] }

        let key = try semanticSearchKey(from: keyData)
        let features = semanticFeatures(from: tokens)
        guard features.isEmpty == false else { return [] }

        let dimensions = 64
        var accumulator = [Double](repeating: 0, count: dimensions)
        let semanticKeyData = PlatformCrypto.symmetricKeyData(key)
        for feature in features {
            let mac = try PlatformCrypto.hmacSHA256(Data(feature.name.utf8), keyData: semanticKeyData)
            let bytes = Array(mac)
            let index = ((Int(bytes[0]) << 8) | Int(bytes[1])) % dimensions
            let sign = (bytes[2] & 1) == 0 ? 1.0 : -1.0
            accumulator[index] += sign * feature.weight
        }

        var hashes: [String] = []
        var seen = Set<String>()
        func appendBucket(_ bucket: String) {
            guard hashes.count < limit else { return }
            guard let mac = try? PlatformCrypto.hmacSHA256(Data(bucket.utf8), keyData: semanticKeyData) else { return }
            let hash = mac.prefix(16).map { String(format: "%02x", $0) }.joined()
            if seen.insert(hash).inserted { hashes.append(hash) }
        }

        let bandSize = 8
        for band in 0..<(dimensions / bandSize) {
            var value = 0
            for bit in 0..<bandSize where accumulator[band * bandSize + bit] >= 0 {
                value |= (1 << bit)
            }
            appendBucket("simhash:v1:band:\(band):\(String(format: "%02x", value))")
        }
        for feature in features.prefix(max(0, limit - hashes.count)) {
            appendBucket("feature:v1:\(feature.name)")
        }
        return hashes
    }

    static func normalizedTokens(from text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && searchStopwords.contains($0) == false }
    }

    static func cloudSearchBodyChunks(
        _ body: String,
        metadata: String,
        maxBytes: Int,
        maxExtractedTokens: Int
    ) throws -> [String] {
        guard maxBytes > 0, maxExtractedTokens > 0 else {
            throw CloudVaultCryptoError.invalidSearchInput
        }
        let metadataTokens = exactPhraseTokens(from: metadata).count
        guard metadataTokens < maxExtractedTokens || exactPhraseTokens(from: body).isEmpty else {
            throw CloudVaultCryptoError.invalidSearchInput
        }

        var pending = utf8Chunks(body, maxBytes: maxBytes)
        var accepted: [String] = []
        while !pending.isEmpty {
            let chunk = pending.removeFirst()
            let searchInput = metadata.isEmpty ? chunk : chunk + " " + metadata
            if exactPhraseTokens(from: searchInput).count <= maxExtractedTokens {
                accepted.append(chunk)
                continue
            }
            guard let split = splitSearchChunk(chunk) else {
                throw CloudVaultCryptoError.invalidSearchInput
            }
            pending.insert(contentsOf: split, at: 0)
        }
        return accepted
    }

    static func exactPhraseTokens(from text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                (token.count >= 2 || token == "x") && searchStopwords.contains(token) == false
            }
    }

    static func semanticFeatureNames(from text: String) -> [String] {
        semanticFeatures(from: exactPhraseTokens(from: text)).map(\.name)
    }

    static func pensieveHMAC(_ value: String, keyData: Data, label: String) throws -> String {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        let key = try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: keyData,
            salt: Data(),
            info: Data("pensieve-dedup:\(label)".utf8),
            outputByteCount: 32
        )
        return try PlatformCrypto.hmacSHA256Hex(
            Data(value.utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
    }

    private static func searchKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data("OpenBurnBar-CloudSearch-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudSearch-TokenHash-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func semanticSearchKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data("OpenBurnBar-CloudSearch-Semantic-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudSearch-SemanticHash-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func tokenHashes(forTerms terms: [String], key: PlatformSymmetricKey, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var hashes: [String] = []
        let keyData = PlatformCrypto.symmetricKeyData(key)
        for term in terms where seen.insert(term).inserted {
            guard let mac = try? PlatformCrypto.hmacSHA256(Data(term.utf8), keyData: keyData) else { continue }
            hashes.append(mac.prefix(16).map { String(format: "%02x", $0) }.joined())
            if hashes.count >= limit { break }
        }
        return hashes
    }

    private static func uniqueNormalizedTokens(from text: String) -> [String] {
        var seen = Set<String>()
        return normalizedTokens(from: text).filter { seen.insert($0).inserted }
    }

    private static func searchIndexPrefixTerms(from tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            let characters = Array(token)
            guard characters.count >= 4 else { return [] }
            let maxPrefixLength = min(16, characters.count - 1)
            guard maxPrefixLength >= 3 else { return [] }
            return (3...maxPrefixLength).map { "prefix:v1:" + String(characters.prefix($0)) }
        }
    }

    private static func searchQueryPrefixTerm(from token: String) -> String? {
        guard token.count >= 3 else { return nil }
        return "prefix:v1:\(String(token.prefix(16)))"
    }

    private static func exactPhraseTerms(from text: String) -> [String] {
        let tokens = exactPhraseTokens(from: text)
        guard tokens.count >= 2 else { return [] }
        var terms: [String] = []
        for index in tokens.indices {
            if index + 1 < tokens.count {
                terms.append("phrase:v1:" + tokens[index...(index + 1)].joined(separator: "_"))
            }
            if index + 2 < tokens.count {
                terms.append("phrase:v1:" + tokens[index...(index + 2)].joined(separator: "_"))
            }
        }
        return terms
    }

    private static func utf8Chunks(_ string: String, maxBytes: Int) -> [String] {
        let data = Data(string.utf8)
        guard data.count > maxBytes else { return [string] }
        var chunks: [String] = []
        var offset = 0
        while offset < data.count {
            var end = min(offset + maxBytes, data.count)
            while end > offset, String(data: data[offset..<end], encoding: .utf8) == nil { end -= 1 }
            guard end > offset, let chunk = String(data: data[offset..<end], encoding: .utf8) else { return [string] }
            chunks.append(chunk)
            offset = end
        }
        return chunks.isEmpty ? [string] : chunks
    }

    private static func splitSearchChunk(_ chunk: String) -> [String]? {
        guard chunk.count > 1 else { return nil }
        let midpoint = chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)
        let delimiter = CharacterSet.alphanumerics.inverted
        let backward = chunk.rangeOfCharacter(from: delimiter, options: .backwards, range: chunk.startIndex..<midpoint)
        let forward = chunk.rangeOfCharacter(from: delimiter, range: midpoint..<chunk.endIndex)
        let splitIndex = backward?.upperBound ?? forward?.upperBound ?? midpoint
        guard splitIndex > chunk.startIndex, splitIndex < chunk.endIndex else { return nil }
        return [String(chunk[..<splitIndex]), String(chunk[splitIndex...])]
    }

    private static func semanticFeatures(from tokens: [String]) -> [SemanticFeature] {
        var features: [SemanticFeature] = []
        var seen = Set<String>()
        func append(_ name: String, weight: Double) {
            guard name.isEmpty == false, seen.insert(name).inserted else { return }
            features.append(SemanticFeature(name: name, weight: weight))
        }
        for concept in semanticConcepts(from: tokens) { append("concept:\(concept)", weight: 3.2) }
        for token in tokens {
            append("token:\(token)", weight: 2.4)
            let stem = simpleSemanticStem(token)
            if stem != token { append("stem:\(stem)", weight: 1.8) }
            if token.count >= 5 { append("prefix:\(String(token.prefix(5)))", weight: 0.8) }
        }
        if tokens.count >= 2 {
            for index in 0..<(tokens.count - 1) {
                append("bigram:\(tokens[index])_\(tokens[index + 1])", weight: 1.3)
            }
        }
        return features
    }

    private static func semanticConcepts(from tokens: [String]) -> [String] {
        var concepts: [String] = []
        var seen = Set<String>()
        func append(_ concept: String) {
            guard seen.insert(concept).inserted else { return }
            concepts.append(concept)
        }
        for token in tokens {
            switch token {
            case "x", "twitter", "tweets", "tweet", "xcom": append("x-platform"); append("social-platform")
            case "ads", "ad", "advertising", "advertise", "campaign", "campaigns", "marketing": append("advertising")
            case "api", "apis", "endpoint", "endpoints", "sdk", "webhook", "webhooks", "integration", "integrations": append("api-integration")
            case "oauth", "auth", "login", "signin", "token", "tokens", "credential", "credentials": append("authentication")
            case "billing", "invoice", "invoices", "pricing", "price", "cost", "spend", "quota", "usage": append("billing-usage")
            case "backup", "sync", "mirror", "cache", "restore", "download", "upload": append("backup-sync")
            default: break
            }
        }
        if concepts.contains("x-platform") && concepts.contains("advertising") { append("x-ads") }
        if concepts.contains("advertising") && concepts.contains("api-integration") { append("ads-api") }
        if concepts.contains("x-platform") && concepts.contains("api-integration") { append("x-api") }
        return concepts
    }

    private static func simpleSemanticStem(_ token: String) -> String {
        let suffixes = ["ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s"]
        for suffix in suffixes where token.count > suffix.count + 3 && token.hasSuffix(suffix) {
            let stem = String(token.dropLast(suffix.count))
            return suffix == "ies" || suffix == "ied" ? stem + "y" : stem
        }
        return token
    }
}
