import Foundation

// MARK: - HNSW Backend

/// HNSW (Hierarchical Navigable Small World) vector index backend providing O(log n) approximate
/// nearest-neighbor search. Drop-in replacement for `BurnBarMappedPersistentVectorIndexBackend`.
public struct BurnBarHNSWVectorIndexBackend: BurnBarPersistentVectorIndexBackend {
    public let backendID: String
    public let backendVersion: String

    /// Maximum connections per layer (M parameter in the HNSW paper).
    public let m: Int
    /// Build-time beam width (efConstruction).
    public let efConstruction: Int
    /// Query-time beam width (efSearch).
    public let efSearch: Int
    /// Quantization strategy for vector storage.
    public let quantization: BurnBarVectorQuantization

    public init(
        m: Int = 16,
        efConstruction: Int = 200,
        efSearch: Int = 64,
        backendID: String = "hnsw",
        backendVersion: String? = nil,
        quantization: BurnBarVectorQuantization = .none
    ) {
        self.m = m
        self.efConstruction = efConstruction
        self.efSearch = efSearch
        self.backendID = backendID
        self.backendVersion = backendVersion ?? (quantization == .none ? "1" : "2")
        self.quantization = quantization
    }

    public func makeWritable(
        dimensions: Int,
        distanceMetric: BurnBarEmbeddingDistanceMetric
    ) throws -> any BurnBarPersistentVectorIndexWritableIndex {
        BurnBarHNSWWritableIndex(
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            m: m,
            efConstruction: efConstruction,
            quantization: quantization
        )
    }

    public func makeReadable(
        dimensions: Int,
        distanceMetric: BurnBarEmbeddingDistanceMetric
    ) throws -> any BurnBarPersistentVectorIndexReadableIndex {
        BurnBarHNSWReadableIndex(
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            efSearch: efSearch
        )
    }
}

// MARK: - HNSW Format

internal enum BurnBarHNSWIndexFormat {
    /// "OBHI" – OpenBurnBar HNSW Index
    static let magic: UInt32 = 0x4F424849
    static let version: UInt32 = 1

    /// v1 header size (36 bytes)
    static let headerSize = 4 + 4 + 4 + 8 + 4 + 4 + 8
    /// v2 header size (52 bytes) adds quantizationType + reserved fields
    static let v2HeaderSize = headerSize + 4 + 4 + 8

    struct Header {
        let version: UInt32
        let dimensions: UInt32
        let count: UInt64
        let m: UInt32
        let maxLevel: UInt32
        let entryPointIndex: UInt64
        let quantizationType: UInt32
    }

    static func parseHeader(from data: Data) throws -> Header {
        guard data.count >= headerSize else {
            throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-hnsw-index"))
        }
        return try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-hnsw-index"))
            }
            let magicVal = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let versionVal = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            guard magicVal == magic else {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-hnsw-index"))
            }
            guard versionVal == 1 || versionVal == 2 else {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-hnsw-index"))
            }
            if versionVal == 2, data.count < v2HeaderSize {
                throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-hnsw-index"))
            }
            var quantizationType: UInt32 = 0
            if versionVal == 2 {
                quantizationType = base.loadUnaligned(fromByteOffset: 36, as: UInt32.self).littleEndian
            }
            return Header(
                version: versionVal,
                dimensions: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian,
                count: base.loadUnaligned(fromByteOffset: 12, as: UInt64.self).littleEndian,
                m: base.loadUnaligned(fromByteOffset: 20, as: UInt32.self).littleEndian,
                maxLevel: base.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian,
                entryPointIndex: base.loadUnaligned(fromByteOffset: 28, as: UInt64.self).littleEndian,
                quantizationType: quantizationType
            )
        }
    }
}

// MARK: - Internal node / graph representation for building

private struct HNSWNode {
    let key: UInt64
    var vector: [Float]
    var level: Int
    /// neighbors[layer] = array of node indices in that layer
    var neighbors: [[UInt32]]
}

// MARK: - Writable Index (Builder)

// AUDIT(@unchecked Sendable): All mutable state (nodes, entryPoint, maxLevel, rng) is
// written only during single-threaded index building via add(key:vector:). The object
// is never shared for concurrent access until building completes and save() is called.
private final class BurnBarHNSWWritableIndex: @unchecked Sendable, BurnBarPersistentVectorIndexWritableIndex {
    private let dimensions: Int
    private let metric: BurnBarEmbeddingDistanceMetric
    private let m: Int
    private let mMax0: Int          // max connections at layer 0 = 2 * m
    private let efConstruction: Int
    private let mL: Double          // 1 / ln(m) for random level assignment

    private var nodes: [HNSWNode] = []
    private var entryPoint: Int = -1
    private var maxLevel: Int = -1
    private var rng = BurnBarHNSWRNG()

    private let quantization: BurnBarVectorQuantization

    init(dimensions: Int, distanceMetric: BurnBarEmbeddingDistanceMetric, m: Int, efConstruction: Int, quantization: BurnBarVectorQuantization = .none) {
        self.dimensions = dimensions
        self.metric = distanceMetric
        self.m = m
        self.mMax0 = 2 * m
        self.efConstruction = efConstruction
        self.mL = 1.0 / log(Double(max(m, 2)))
        self.quantization = quantization
    }

    func reserve(_ count: Int) throws {
        nodes.reserveCapacity(count)
    }

    func add(key: UInt64, vector: [Float]) throws {
        guard vector.count == dimensions else {
            throw BurnBarPersistentVectorIndexError.invalidVectorDimensions(expected: dimensions, actual: vector.count)
        }

        let prepared = hnswPreparedVector(vector, metric: metric)
        let nodeLevel = randomLevel()
        let nodeIndex = nodes.count

        var neighbors = [[UInt32]]()
        neighbors.reserveCapacity(nodeLevel + 1)
        for _ in 0 ... nodeLevel {
            neighbors.append([])
        }
        let node = HNSWNode(key: key, vector: prepared, level: nodeLevel, neighbors: neighbors)
        nodes.append(node)

        if entryPoint < 0 {
            // First node
            entryPoint = nodeIndex
            maxLevel = nodeLevel
            return
        }

        var currentNode = entryPoint

        // Phase 1: greedily traverse layers above the new node's level
        for layer in stride(from: maxLevel, through: nodeLevel + 1, by: -1) {
            currentNode = greedyClosest(to: prepared, from: currentNode, layer: layer)
        }

        // Phase 2: insert at each layer from min(nodeLevel, maxLevel) down to 0
        let insertionTop = min(nodeLevel, maxLevel)
        for layer in stride(from: insertionTop, through: 0, by: -1) {
            let candidates = searchLayer(query: prepared, entryPoints: [UInt32(currentNode)], ef: efConstruction, layer: layer)

            // Select M closest neighbors from candidates (always M, not maxConn)
            let selected = selectNeighbors(from: candidates, count: m)

            // Connect new node to selected neighbors
            nodes[nodeIndex].neighbors[layer] = selected.map(\.index)

            // Connect neighbors back to new node, pruning if necessary
            for neighbor in selected {
                let neighborIdx = Int(neighbor.index)
                nodes[neighborIdx].neighbors[layer].append(UInt32(nodeIndex))
                let neighborMaxConn = layer == 0 ? mMax0 : m
                if nodes[neighborIdx].neighbors[layer].count > neighborMaxConn {
                    // Prune: keep only the closest neighborMaxConn connections
                    let neighborVec = nodes[neighborIdx].vector
                    var scored: [(index: UInt32, dist: Float)] = nodes[neighborIdx].neighbors[layer].map { idx in
                        (idx, hnswDistance(lhs: neighborVec, rhs: nodes[Int(idx)].vector, metric: metric))
                    }
                    scored.sort { $0.dist < $1.dist }
                    nodes[neighborIdx].neighbors[layer] = Array(scored.prefix(neighborMaxConn).map(\.index))
                }
            }

            // Update entry point for next layer
            if let closest = selected.first {
                currentNode = Int(closest.index)
            }
        }

        // Update entry point if new node has a higher level
        if nodeLevel > maxLevel {
            entryPoint = nodeIndex
            maxLevel = nodeLevel
        }
    }

    func save(to url: URL) throws {
        let quantizer: BurnBarScalarQuantizer?
        if quantization == .scalarUInt8, !nodes.isEmpty {
            var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
            for node in nodes {
                builder.accumulate(vector: node.vector)
            }
            quantizer = builder.build()
        } else {
            quantizer = nil
        }

        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // Write header
        let fileVersion: UInt32 = quantizer != nil ? 2 : BurnBarHNSWIndexFormat.version
        var magic = BurnBarHNSWIndexFormat.magic.littleEndian
        var version = fileVersion.littleEndian
        var dims = UInt32(dimensions).littleEndian
        var count = UInt64(nodes.count).littleEndian
        var mLE = UInt32(m).littleEndian
        var maxLevelLE = UInt32(max(maxLevel, 0)).littleEndian
        var epLE = UInt64(max(entryPoint, 0)).littleEndian

        try withUnsafeBytes(of: &magic) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &version) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &dims) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &mLE) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &maxLevelLE) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &epLE) { try handle.write(contentsOf: $0) }

        if fileVersion >= 2 {
            var quantizationType = UInt32(quantizer != nil ? 1 : 0).littleEndian
            var reserved1 = UInt32(0).littleEndian
            var reserved2 = UInt64(0).littleEndian
            try withUnsafeBytes(of: &quantizationType) { try handle.write(contentsOf: $0) }
            try withUnsafeBytes(of: &reserved1) { try handle.write(contentsOf: $0) }
            try withUnsafeBytes(of: &reserved2) { try handle.write(contentsOf: $0) }
        }

        if let quantizer = quantizer {
            try quantizer.write(to: handle)
        }

        // Write each node: key(UInt64), level(UInt32), vector, then per-layer neighbors
        for node in nodes {
            var keyLE = node.key.littleEndian
            var levelLE = UInt32(node.level).littleEndian
            try withUnsafeBytes(of: &keyLE) { try handle.write(contentsOf: $0) }
            try withUnsafeBytes(of: &levelLE) { try handle.write(contentsOf: $0) }

            // Write vector
            if let quantizer = quantizer {
                let encoded = quantizer.encode(vector: node.vector)
                try encoded.withUnsafeBufferPointer { buffer in
                    try handle.write(contentsOf: UnsafeRawBufferPointer(buffer))
                }
            } else {
                try node.vector.withUnsafeBufferPointer { buffer in
                    try handle.write(contentsOf: UnsafeRawBufferPointer(buffer))
                }
            }

            // Write neighbors for each layer 0..level
            for layer in 0 ... node.level {
                let layerNeighbors = node.neighbors[layer]
                var neighborCount = UInt32(layerNeighbors.count).littleEndian
                try withUnsafeBytes(of: &neighborCount) { try handle.write(contentsOf: $0) }
                for var idx in layerNeighbors {
                    idx = idx.littleEndian
                    try withUnsafeBytes(of: &idx) { try handle.write(contentsOf: $0) }
                }
            }
        }
    }

    // MARK: - HNSW graph operations

    private func randomLevel() -> Int {
        let uniform = rng.nextDouble()
        // level = floor(-ln(uniform) * mL) per HNSW paper
        let level = Int(-log(max(uniform, 1e-15)) * mL)
        return level
    }

    /// Greedy search for the single closest node at a given layer.
    private func greedyClosest(to query: [Float], from start: Int, layer: Int) -> Int {
        var current = start
        var currentDist = hnswDistance(lhs: query, rhs: nodes[current].vector, metric: metric)

        while true {
            var changed = false
            let neighbors = nodes[current].neighbors
            guard layer < neighbors.count else { break }
            for neighborIdx in neighbors[layer] {
                let dist = hnswDistance(lhs: query, rhs: nodes[Int(neighborIdx)].vector, metric: metric)
                if dist < currentDist {
                    currentDist = dist
                    current = Int(neighborIdx)
                    changed = true
                }
            }
            if !changed { break }
        }
        return current
    }

    private struct ScoredIndex: Comparable {
        let index: UInt32
        let distance: Float

        static func < (lhs: ScoredIndex, rhs: ScoredIndex) -> Bool {
            lhs.distance < rhs.distance
        }
    }

    /// Beam search at a given layer returning up to `ef` candidates sorted by distance (ascending = closest first).
    private func searchLayer(query: [Float], entryPoints: [UInt32], ef: Int, layer: Int) -> [ScoredIndex] {
        var visited = Set<UInt32>(entryPoints)
        // candidates: sorted ascending by distance (closest first)
        var candidates: [ScoredIndex] = entryPoints.map { idx in
            ScoredIndex(index: idx, distance: hnswDistance(lhs: query, rhs: nodes[Int(idx)].vector, metric: metric))
        }
        candidates.sort()

        // results: keep up to ef closest
        var results = candidates

        var candidateIdx = 0
        while candidateIdx < candidates.count {
            let current = candidates[candidateIdx]
            candidateIdx += 1

            // If current candidate is farther than the worst result, stop
            if results.count >= ef, current.distance > results[ef - 1].distance {
                break
            }

            let nodeNeighbors = nodes[Int(current.index)].neighbors
            guard layer < nodeNeighbors.count else { continue }

            for neighborIdx in nodeNeighbors[layer] {
                guard visited.insert(neighborIdx).inserted else { continue }
                let dist = hnswDistance(lhs: query, rhs: nodes[Int(neighborIdx)].vector, metric: metric)

                let shouldInsert = results.count < ef || dist < results[results.count - 1].distance
                guard shouldInsert else { continue }

                let entry = ScoredIndex(index: neighborIdx, distance: dist)

                // Insert into results maintaining sorted order
                let insertPos = results.binarySearchInsertionIndex(for: entry)
                results.insert(entry, at: insertPos)
                if results.count > ef {
                    results.removeLast()
                }

                // Insert into candidates maintaining sorted order
                let candInsertPos = candidates.binarySearchInsertionIndex(for: entry)
                candidates.insert(entry, at: candInsertPos)
                // Adjust candidateIdx if insertion shifted elements before current position
                if candInsertPos < candidateIdx {
                    candidateIdx += 1
                }
            }
        }

        return results
    }

    /// Simple neighbor selection: pick the `count` closest candidates.
    private func selectNeighbors(from candidates: [ScoredIndex], count: Int) -> [ScoredIndex] {
        Array(candidates.prefix(count))
    }
}

// MARK: - Readable Index

// AUDIT(@unchecked Sendable): `loadedData` is set once via load()/view() before the object
// is shared for concurrent reads; no further mutation occurs after initialization.
private final class BurnBarHNSWReadableIndex: @unchecked Sendable, BurnBarPersistentVectorIndexReadableIndex {
    private let dimensions: Int
    private let metric: BurnBarEmbeddingDistanceMetric
    private let efSearch: Int
    private var loadedData: Data?
    private var quantizer: BurnBarScalarQuantizer?

    init(dimensions: Int, distanceMetric: BurnBarEmbeddingDistanceMetric, efSearch: Int) {
        self.dimensions = dimensions
        self.metric = distanceMetric
        self.efSearch = efSearch
    }

    func load(from url: URL) throws {
        loadedData = try Data(contentsOf: url)
        try parseQuantizerIfNeeded()
    }

    func view(from url: URL) throws {
        loadedData = try Data(contentsOf: url, options: [.mappedIfSafe])
        try parseQuantizerIfNeeded()
    }

    private func parseQuantizerIfNeeded() throws {
        guard let data = loadedData else {
            quantizer = nil
            return
        }
        let header = try BurnBarHNSWIndexFormat.parseHeader(from: data)
        guard header.version >= 2, header.quantizationType == 1 else {
            quantizer = nil
            return
        }
        guard let (q, _) = BurnBarScalarQuantizer.read(from: data, dimensions: dimensions, offset: BurnBarHNSWIndexFormat.v2HeaderSize) else {
            throw BurnBarPersistentVectorIndexError.missingIndexFile(URL(fileURLWithPath: "corrupt-hnsw-index"))
        }
        quantizer = q
    }

    func search(vector: [Float], limit: Int) throws -> ([UInt64], [Float]) {
        guard let data = loadedData else { return ([], []) }
        guard limit > 0 else { return ([], []) }

        let header = try BurnBarHNSWIndexFormat.parseHeader(from: data)
        guard Int(header.dimensions) == dimensions else {
            throw BurnBarPersistentVectorIndexError.invalidVectorDimensions(
                expected: dimensions,
                actual: Int(header.dimensions)
            )
        }
        guard header.count > 0 else { return ([], []) }

        let query = hnswPreparedVector(vector, metric: metric)

        // Determine data layout based on version and quantization
        let baseHeaderSize = header.version >= 2 ? BurnBarHNSWIndexFormat.v2HeaderSize : BurnBarHNSWIndexFormat.headerSize
        let quantizerDataSize = quantizer != nil ? 2 * dimensions * MemoryLayout<Float>.size : 0
        let vectorByteSize = quantizer != nil ? dimensions * MemoryLayout<UInt8>.size : dimensions * MemoryLayout<Float>.size

        // Parse the graph from the serialized data
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return ([], []) }
            let totalCount = Int(header.count)
            let _ = Int(header.m)  // M parameter preserved in header for future use
            let maxLevel = Int(header.maxLevel)
            let entryPointIndex = Int(header.entryPointIndex)

            // Pre-parse: build an array of (key, vectorOffset, level, neighborsPerLayer) for each node
            struct NodeMeta {
                let key: UInt64
                let vectorOffset: Int
                let level: Int
                var layerNeighborInfo: [(offset: Int, count: Int)]
            }

            var nodeMetas: [NodeMeta] = []
            nodeMetas.reserveCapacity(totalCount)

            var offset = baseHeaderSize + quantizerDataSize
            for _ in 0 ..< totalCount {
                let key = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
                offset += MemoryLayout<UInt64>.size
                let level = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
                offset += MemoryLayout<UInt32>.size

                let vectorOffset = offset
                offset += vectorByteSize

                var layerInfo: [(offset: Int, count: Int)] = []
                layerInfo.reserveCapacity(level + 1)
                for _ in 0 ... level {
                    let neighborCount = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
                    offset += MemoryLayout<UInt32>.size
                    let neighborsOffset = offset
                    offset += neighborCount * MemoryLayout<UInt32>.size
                    layerInfo.append((neighborsOffset, neighborCount))
                }

                nodeMetas.append(NodeMeta(key: key, vectorOffset: vectorOffset, level: level, layerNeighborInfo: layerInfo))
            }

            // Helper: compute distance from query to a node
            func distanceToNode(_ nodeIdx: Int) -> Float {
                let meta = nodeMetas[nodeIdx]
                if let quantizer = self.quantizer {
                    let bytePtr = base.advanced(by: meta.vectorOffset).assumingMemoryBound(to: UInt8.self)
                    let buffer = UnsafeBufferPointer(start: bytePtr, count: self.dimensions)
                    return hnswQuantizedDistanceFromBuffer(lhs: query, rhs: buffer, quantizer: quantizer, metric: self.metric)
                } else {
                    let floatPtr = base.advanced(by: meta.vectorOffset).assumingMemoryBound(to: Float.self)
                    let buffer = UnsafeBufferPointer(start: floatPtr, count: self.dimensions)
                    return hnswDistanceFromBuffer(lhs: query, rhs: buffer, metric: self.metric)
                }
            }

            // Helper: get neighbors of a node at a given layer
            func neighborsOf(_ nodeIdx: Int, layer: Int) -> UnsafeBufferPointer<UInt32> {
                let meta = nodeMetas[nodeIdx]
                guard layer < meta.layerNeighborInfo.count else {
                    return UnsafeBufferPointer(start: nil, count: 0)
                }
                let info = meta.layerNeighborInfo[layer]
                guard info.count > 0 else {
                    return UnsafeBufferPointer(start: nil, count: 0)
                }
                let ptr = base.advanced(by: info.offset).assumingMemoryBound(to: UInt32.self)
                return UnsafeBufferPointer(start: ptr, count: info.count)
            }

            // HNSW search algorithm
            var currentNode = entryPointIndex

            // Phase 1: greedy descent from top layer to layer 1
            for layer in stride(from: maxLevel, through: 1, by: -1) {
                var currentDist = distanceToNode(currentNode)
                var changed = true
                while changed {
                    changed = false
                    let nbrs = neighborsOf(currentNode, layer: layer)
                    for i in 0 ..< nbrs.count {
                        let nIdx = Int(nbrs[i].littleEndian)
                        let dist = distanceToNode(nIdx)
                        if dist < currentDist {
                            currentDist = dist
                            currentNode = nIdx
                            changed = true
                        }
                    }
                }
            }

            // Phase 2: beam search at layer 0
            let ef = max(self.efSearch, limit)

            struct ScoredNode: Comparable {
                let index: Int
                let distance: Float
                static func < (lhs: ScoredNode, rhs: ScoredNode) -> Bool {
                    lhs.distance < rhs.distance
                }
            }

            var visited = Set<Int>()
            visited.insert(currentNode)

            let entryDist = distanceToNode(currentNode)
            var candidates = [ScoredNode(index: currentNode, distance: entryDist)]
            var results = candidates

            var candIdx = 0
            while candIdx < candidates.count {
                let current = candidates[candIdx]
                candIdx += 1

                if results.count >= ef, current.distance > results[ef - 1].distance {
                    break
                }

                let nbrs = neighborsOf(current.index, layer: 0)
                for i in 0 ..< nbrs.count {
                    let nIdx = Int(nbrs[i].littleEndian)
                    guard visited.insert(nIdx).inserted else { continue }
                    let dist = distanceToNode(nIdx)

                    let shouldInsert = results.count < ef || dist < results[results.count - 1].distance
                    guard shouldInsert else { continue }

                    let entry = ScoredNode(index: nIdx, distance: dist)

                    // Binary insertion into results
                    var lo = 0, hi = results.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if results[mid].distance < entry.distance {
                            lo = mid + 1
                        } else {
                            hi = mid
                        }
                    }
                    results.insert(entry, at: lo)
                    if results.count > ef {
                        results.removeLast()
                    }

                    // Binary insertion into candidates
                    lo = 0; hi = candidates.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if candidates[mid].distance < entry.distance {
                            lo = mid + 1
                        } else {
                            hi = mid
                        }
                    }
                    candidates.insert(entry, at: lo)
                    if lo < candIdx {
                        candIdx += 1
                    }
                }
            }

            // Convert distance back to similarity score and take top `limit`
            let topResults = results.prefix(limit)
            let keys: [UInt64] = topResults.map { nodeMetas[$0.index].key }
            let scores: [Float] = topResults.map { hnswDistanceToSimilarity($0.distance, metric: self.metric) }

            return (keys, scores)
        }
    }
}

// MARK: - Distance / Similarity Helpers

/// Prepares a vector for HNSW distance computation (L2-normalizes for cosine metric).
/// Uses SIMD-accelerated normalization when available.
private func hnswPreparedVector(_ vector: [Float], metric: BurnBarEmbeddingDistanceMetric) -> [Float] {
    switch metric {
    case .cosine:
        return BurnBarVectorMath.simdL2Normalized(vector)
    case .dotProduct, .euclidean:
        return vector
    }
}

/// Computes distance (lower = more similar) for HNSW graph construction and search.
/// Uses SIMD-accelerated dot product and Euclidean distance via vDSP when available.
/// For cosine: 1 - dot(a, b) on L2-normalized vectors  (range [0, 2])
/// For dotProduct: -dot(a, b)  (negate so lower = better)
/// For euclidean: L2 distance
private func hnswDistance(lhs: [Float], rhs: [Float], metric: BurnBarEmbeddingDistanceMetric) -> Float {
    switch metric {
    case .cosine:
        return 1.0 - BurnBarVectorMath.simdDotProductF(lhs: lhs, rhs: rhs)
    case .dotProduct:
        return -BurnBarVectorMath.simdDotProductF(lhs: lhs, rhs: rhs)
    case .euclidean:
        return sqrt(BurnBarVectorMath.simdEuclideanDistanceSqF(lhs: lhs, rhs: rhs))
    }
}

/// Buffer-based variant for read-path performance (avoids array copy).
/// Uses SIMD-accelerated dot product via vDSP when available.
private func hnswDistanceFromBuffer(lhs: [Float], rhs: UnsafeBufferPointer<Float>, metric: BurnBarEmbeddingDistanceMetric) -> Float {
    switch metric {
    case .cosine:
        return 1.0 - BurnBarVectorMath.simdDotProductF(lhs: lhs, rhs: rhs)
    case .dotProduct:
        return -BurnBarVectorMath.simdDotProductF(lhs: lhs, rhs: rhs)
    case .euclidean:
        return sqrt(BurnBarVectorMath.simdEuclideanDistanceSqF(lhs: lhs, rhs: rhs))
    }
}

/// Quantized buffer-based distance for read-path performance with scalar quantization.
private func hnswQuantizedDistanceFromBuffer(lhs: [Float], rhs: UnsafeBufferPointer<UInt8>, quantizer: BurnBarScalarQuantizer, metric: BurnBarEmbeddingDistanceMetric) -> Float {
    switch metric {
    case .cosine:
        return 1.0 - quantizer.quantizedDotProduct(query: lhs, bytes: rhs)
    case .dotProduct:
        return -quantizer.quantizedDotProduct(query: lhs, bytes: rhs)
    case .euclidean:
        return sqrt(quantizer.quantizedEuclideanDistanceSq(query: lhs, bytes: rhs))
    }
}

/// Converts an HNSW distance back to the similarity score expected by the search API.
private func hnswDistanceToSimilarity(_ distance: Float, metric: BurnBarEmbeddingDistanceMetric) -> Float {
    switch metric {
    case .cosine:
        return 1.0 - distance  // dot product of normalized vectors
    case .dotProduct:
        return -distance       // undo negation
    case .euclidean:
        return -distance       // negative euclidean distance
    }
}

// MARK: - Binary Search Extension

private extension Array where Element: Comparable {
    /// Returns the index at which `element` should be inserted to keep the array sorted ascending.
    func binarySearchInsertionIndex(for element: Element) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid] < element {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

// MARK: - Deterministic-seed PRNG for reproducible level assignment

/// Splitmix64-based PRNG. Deterministic within a process; no external seed required
/// because the HNSW algorithm's correctness does not depend on randomness quality.
private struct BurnBarHNSWRNG {
    private var state: UInt64

    init(seed: UInt64 = 0xBEEF_CAFE_DEAD_BEEF) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
