import CryptoKit
import Foundation

public enum BurnBarPersistentVectorIndexError: LocalizedError {
    case missingIndexFile(URL)
    case missingChunkIDForKey(UInt64)
    case invalidVectorDimensions(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .missingIndexFile(let url):
            return "Persistent vector index is missing at \(url.path)."
        case .missingChunkIDForKey(let key):
            return "Persistent vector index key \(key) is missing a chunk identifier mapping."
        case .invalidVectorDimensions(let expected, let actual):
            return "Persistent vector index expected \(expected) dimensions but received \(actual)."
        }
    }
}

public struct BurnBarPersistentVectorIndexFiles: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var indexURL: URL { directoryURL.appendingPathComponent("index.usearch") }
    public var manifestURL: URL { directoryURL.appendingPathComponent("manifest.json") }
    public var keyMappingURL: URL { directoryURL.appendingPathComponent("keys.json") }
}

public struct BurnBarPersistentVectorIndexManifest: Codable, Sendable {
    public let backendID: String
    public let backendVersion: String
    public let embeddingVersionID: String
    public let fingerprint: String
    public let dimensions: Int
    public let distanceMetric: BurnBarEmbeddingDistanceMetric
    public let vectorCount: Int
    public let builtAt: Date
    public let quantization: BurnBarVectorQuantization?

    public init(
        backendID: String,
        backendVersion: String,
        embeddingVersionID: String,
        fingerprint: String,
        dimensions: Int,
        distanceMetric: BurnBarEmbeddingDistanceMetric,
        vectorCount: Int,
        builtAt: Date,
        quantization: BurnBarVectorQuantization? = nil
    ) {
        self.backendID = backendID
        self.backendVersion = backendVersion
        self.embeddingVersionID = embeddingVersionID
        self.fingerprint = fingerprint
        self.dimensions = dimensions
        self.distanceMetric = distanceMetric
        self.vectorCount = vectorCount
        self.builtAt = builtAt
        self.quantization = quantization
    }
}

public protocol BurnBarPersistentVectorIndexWritableIndex: Sendable {
    func reserve(_ count: Int) throws
    func add(key: UInt64, vector: [Float]) throws
    func save(to url: URL) throws
}

public protocol BurnBarPersistentVectorIndexReadableIndex: Sendable {
    func load(from url: URL) throws
    func view(from url: URL) throws
    func search(vector: [Float], limit: Int) throws -> ([UInt64], [Float])
}

public protocol BurnBarPersistentVectorIndexBackend: Sendable {
    var backendID: String { get }
    var backendVersion: String { get }
    func makeWritable(dimensions: Int, distanceMetric: BurnBarEmbeddingDistanceMetric) throws -> any BurnBarPersistentVectorIndexWritableIndex
    func makeReadable(dimensions: Int, distanceMetric: BurnBarEmbeddingDistanceMetric) throws -> any BurnBarPersistentVectorIndexReadableIndex
}

public enum BurnBarPersistentVectorIndexFactory {
    public static func defaultBackend() -> any BurnBarPersistentVectorIndexBackend {
        hnswBackend()
    }

    /// Creates an HNSW approximate nearest-neighbor backend (O(log n) search).
    public static func hnswBackend(
        m: Int = 16,
        efConstruction: Int = 200,
        efSearch: Int = 64,
        quantization: BurnBarVectorQuantization = .none
    ) -> any BurnBarPersistentVectorIndexBackend {
        BurnBarHNSWVectorIndexBackend(m: m, efConstruction: efConstruction, efSearch: efSearch, quantization: quantization)
    }

    /// Creates the brute-force exact-search backend (O(n) linear scan).
    public static func exactBackend() -> any BurnBarPersistentVectorIndexBackend {
        BurnBarMappedPersistentVectorIndexBackend()
    }
}

public enum BurnBarPersistentVectorIndexKeyCodec {
    public static func makeMapping(chunkIDs: [String]) throws -> [String: UInt64] {
        var usedKeys: [UInt64: String] = [:]
        usedKeys.reserveCapacity(chunkIDs.count)
        var mapping: [String: UInt64] = [:]
        mapping.reserveCapacity(chunkIDs.count)

        for chunkID in chunkIDs.sorted() {
            var salt: UInt64 = 0
            while true {
                let key = stableKey(for: chunkID, salt: salt)
                if let existing = usedKeys[key], existing != chunkID {
                    salt &+= 1
                    continue
                }
                usedKeys[key] = chunkID
                mapping[chunkID] = key
                break
            }
        }

        return mapping
    }

    private static func stableKey(for chunkID: String, salt: UInt64) -> UInt64 {
        let payload = Data((salt == 0 ? chunkID : "\(salt):\(chunkID)").utf8)
        let digest = SHA256.hash(data: payload)
        let key = digest.prefix(8).reduce(UInt64.zero) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
        return key == 0 ? 1 : key
    }
}

public enum BurnBarPersistentVectorIndexSnapshotIO {
    public static func writeManifest(_ manifest: BurnBarPersistentVectorIndexManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    public static func readManifest(from url: URL) throws -> BurnBarPersistentVectorIndexManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BurnBarPersistentVectorIndexManifest.self, from: Data(contentsOf: url))
    }

    public static func writeKeyMapping(_ keyByChunkID: [String: UInt64], to url: URL) throws {
        let keyToChunkID = Dictionary(uniqueKeysWithValues: keyByChunkID.map { ($1, $0) })
        let data = try JSONEncoder().encode(keyToChunkID)
        try data.write(to: url, options: .atomic)
    }

    public static func readKeyMapping(from url: URL) throws -> [UInt64: String] {
        try JSONDecoder().decode([UInt64: String].self, from: Data(contentsOf: url))
    }

    public static func fileByteCount(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

public final class BurnBarPersistentVectorIndexSnapshot: Sendable {
    public let manifest: BurnBarPersistentVectorIndexManifest
    public let files: BurnBarPersistentVectorIndexFiles

    private let index: any BurnBarPersistentVectorIndexReadableIndex
    private let chunkIDByKey: [UInt64: String]

    private init(
        manifest: BurnBarPersistentVectorIndexManifest,
        files: BurnBarPersistentVectorIndexFiles,
        index: any BurnBarPersistentVectorIndexReadableIndex,
        chunkIDByKey: [UInt64: String]
    ) {
        self.manifest = manifest
        self.files = files
        self.index = index
        self.chunkIDByKey = chunkIDByKey
    }

    public static func open(
        files: BurnBarPersistentVectorIndexFiles,
        backend: any BurnBarPersistentVectorIndexBackend
    ) throws -> BurnBarPersistentVectorIndexSnapshot {
        guard FileManager.default.fileExists(atPath: files.indexURL.path) else {
            throw BurnBarPersistentVectorIndexError.missingIndexFile(files.indexURL)
        }

        let manifest = try BurnBarPersistentVectorIndexSnapshotIO.readManifest(from: files.manifestURL)
        let chunkIDByKey = try BurnBarPersistentVectorIndexSnapshotIO.readKeyMapping(from: files.keyMappingURL)
        let index = try backend.makeReadable(
            dimensions: manifest.dimensions,
            distanceMetric: manifest.distanceMetric
        )
        try index.view(from: files.indexURL)
        return BurnBarPersistentVectorIndexSnapshot(
            manifest: manifest,
            files: files,
            index: index,
            chunkIDByKey: chunkIDByKey
        )
    }

    public func candidates(for query: [Float], limit: Int) throws -> [BurnBarSemanticCandidate] {
        guard query.count == manifest.dimensions else {
            throw BurnBarPersistentVectorIndexError.invalidVectorDimensions(
                expected: manifest.dimensions,
                actual: query.count
            )
        }

        let prepared = preparedVector(query, metric: manifest.distanceMetric)
        let (keys, distances) = try index.search(vector: prepared, limit: limit)
        return try zip(keys, distances).enumerated().map { index, pair in
            guard let chunkID = chunkIDByKey[pair.0] else {
                throw BurnBarPersistentVectorIndexError.missingChunkIDForKey(pair.0)
            }
            return BurnBarSemanticCandidate(chunkID: chunkID, score: Double(pair.1), rank: index + 1)
        }
    }
}

public struct BurnBarMappedPersistentVectorIndexBackend: BurnBarPersistentVectorIndexBackend {
    public let backendID: String
    public let backendVersion: String

    public init(backendID: String = "mapped_exact", backendVersion: String = "1") {
        self.backendID = backendID
        self.backendVersion = backendVersion
    }

    public func makeWritable(
        dimensions: Int,
        distanceMetric: BurnBarEmbeddingDistanceMetric
    ) throws -> any BurnBarPersistentVectorIndexWritableIndex {
        try BurnBarMappedWritableIndex(dimensions: dimensions, distanceMetric: distanceMetric)
    }

    public func makeReadable(
        dimensions: Int,
        distanceMetric: BurnBarEmbeddingDistanceMetric
    ) throws -> any BurnBarPersistentVectorIndexReadableIndex {
        BurnBarMappedReadableIndex(dimensions: dimensions, distanceMetric: distanceMetric)
    }
}

// AUDIT(@unchecked Sendable): Mutable `count` is write-only during single-threaded
// index building; the resulting object is never shared until building completes.
private final class BurnBarMappedWritableIndex: @unchecked Sendable, BurnBarPersistentVectorIndexWritableIndex {
    private let dimensions: Int
    private let metric: BurnBarEmbeddingDistanceMetric
    private let bodyURL: URL
    private let handle: FileHandle
    private var count = 0

    init(dimensions: Int, distanceMetric: BurnBarEmbeddingDistanceMetric) throws {
        self.dimensions = dimensions
        metric = distanceMetric
        bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-vector-body-\(UUID().uuidString)", isDirectory: false)
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: bodyURL)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: bodyURL)
    }

    func reserve(_ count: Int) throws {}

    func add(key: UInt64, vector: [Float]) throws {
        guard vector.count == dimensions else {
            throw BurnBarPersistentVectorIndexError.invalidVectorDimensions(expected: dimensions, actual: vector.count)
        }

        var keyLE = key.littleEndian
        try withUnsafeBytes(of: &keyLE) { bytes in
            try handle.write(contentsOf: bytes)
        }

        let prepared = preparedVector(vector, metric: metric)
        try prepared.withUnsafeBufferPointer { buffer in
            try handle.write(contentsOf: UnsafeRawBufferPointer(buffer))
        }
        count += 1
    }

    func save(to url: URL) throws {
        try handle.close()
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }

        var magic = BurnBarMappedIndexFormat.magic
        try withUnsafeBytes(of: &magic) { bytes in
            try output.write(contentsOf: bytes)
        }

        var version = BurnBarMappedIndexFormat.version.littleEndian
        var dimensionsLE = UInt32(dimensions).littleEndian
        var countLE = UInt64(count).littleEndian
        try withUnsafeBytes(of: &version) { try output.write(contentsOf: $0) }
        try withUnsafeBytes(of: &dimensionsLE) { try output.write(contentsOf: $0) }
        try withUnsafeBytes(of: &countLE) { try output.write(contentsOf: $0) }

        let input = try FileHandle(forReadingFrom: bodyURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), chunk.isEmpty == false {
            try output.write(contentsOf: chunk)
        }
    }
}

// AUDIT(@unchecked Sendable): `mappedData` is set once via load() before the object
// is shared for concurrent reads; no further mutation occurs after initialization.
private final class BurnBarMappedReadableIndex: @unchecked Sendable, BurnBarPersistentVectorIndexReadableIndex {
    private let dimensions: Int
    private let metric: BurnBarEmbeddingDistanceMetric
    private var mappedData: Data?

    init(dimensions: Int, distanceMetric: BurnBarEmbeddingDistanceMetric) {
        self.dimensions = dimensions
        metric = distanceMetric
    }

    func load(from url: URL) throws {
        mappedData = try Data(contentsOf: url)
    }

    func view(from url: URL) throws {
        mappedData = try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func search(vector: [Float], limit: Int) throws -> ([UInt64], [Float]) {
        guard let mappedData else { return ([], []) }
        let query = preparedVector(vector, metric: metric)
        let header = try BurnBarMappedIndexFormat.parseHeader(from: mappedData)
        guard Int(header.dimensions) == dimensions else {
            throw BurnBarPersistentVectorIndexError.invalidVectorDimensions(expected: dimensions, actual: Int(header.dimensions))
        }

        var best: [(key: UInt64, score: Float)] = []
        best.reserveCapacity(limit)
        let recordStride = MemoryLayout<UInt64>.size + dimensions * MemoryLayout<Float>.size

        try mappedData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = BurnBarMappedIndexFormat.headerSize

            for _ in 0 ..< Int(header.count) {
                let key = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
                offset += MemoryLayout<UInt64>.size

                let floatBase = base.advanced(by: offset).assumingMemoryBound(to: Float.self)
                let buffer = UnsafeBufferPointer(start: floatBase, count: dimensions)
                let score = Float(similarity(lhs: query, rhs: buffer, metric: metric))
                offset += dimensions * MemoryLayout<Float>.size

                if best.count < limit {
                    best.append((key, score))
                    best.sort(by: mappedCandidateOrder)
                } else if let last = best.last, mappedCandidateOrder((key, score), last) {
                    best.removeLast()
                    best.append((key, score))
                    best.sort(by: mappedCandidateOrder)
                }
            }

            let expectedSize = BurnBarMappedIndexFormat.headerSize + Int(header.count) * recordStride
            guard rawBuffer.count >= expectedSize else {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-index"))
            }
        }

        return (
            best.map(\.key),
            best.map(\.score)
        )
    }
}

private func preparedVector(_ vector: [Float], metric: BurnBarEmbeddingDistanceMetric) -> [Float] {
    switch metric {
    case .cosine:
        return BurnBarVectorMath.l2Normalized(vector)
    case .dotProduct, .euclidean:
        return vector
    }
}

private func mappedCandidateOrder(_ lhs: (key: UInt64, score: Float), _ rhs: (key: UInt64, score: Float)) -> Bool {
    if lhs.score == rhs.score {
        return lhs.key < rhs.key
    }
    return lhs.score > rhs.score
}

private func similarity(
    lhs: [Float],
    rhs: UnsafeBufferPointer<Float>,
    metric: BurnBarEmbeddingDistanceMetric
) -> Double {
    switch metric {
    case .cosine:
        var dot: Double = 0
        var rhsNorm: Double = 0
        for index in lhs.indices {
            let l = Double(lhs[index])
            let r = Double(rhs[index])
            dot += l * r
            rhsNorm += r * r
        }
        guard rhsNorm > 0 else { return 0 }
        return dot / sqrt(rhsNorm)
    case .dotProduct:
        var dot: Double = 0
        for index in lhs.indices {
            dot += Double(lhs[index]) * Double(rhs[index])
        }
        return dot
    case .euclidean:
        var sumSquares: Double = 0
        for index in lhs.indices {
            let diff = Double(lhs[index] - rhs[index])
            sumSquares += diff * diff
        }
        return -sqrt(sumSquares)
    }
}

private enum BurnBarMappedIndexFormat {
    static let magic: UInt32 = 0x4F425649 // OBVI
    static let version: UInt32 = 1
    static let headerSize = MemoryLayout<UInt32>.size * 3 + MemoryLayout<UInt64>.size

    struct Header {
        let dimensions: UInt32
        let count: UInt64
    }

    static func parseHeader(from data: Data) throws -> Header {
        guard data.count >= headerSize else {
            throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-index"))
        }

        return try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-index"))
            }
            let magicValue = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let versionValue = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            let dimensionsValue = base.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
            let countValue = base.loadUnaligned(fromByteOffset: 12, as: UInt64.self).littleEndian
            guard magicValue == magic, versionValue == version else {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-index"))
            }
            return Header(dimensions: dimensionsValue, count: countValue)
        }
    }
}
