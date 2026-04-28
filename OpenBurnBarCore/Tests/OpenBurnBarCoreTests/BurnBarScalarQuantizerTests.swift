import Foundation
import XCTest
@testable import OpenBurnBarCore

final class BurnBarScalarQuantizerTests: XCTestCase {

    func test_roundTrip_encodeDecode_accuracy() {
        let dimensions = 64
        var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        var vectors: [[Float]] = []
        for i in 0..<100 {
            var v = [Float](repeating: 0, count: dimensions)
            for j in 0..<dimensions {
                v[j] = sin(Float(i) * 0.1 + Float(j) * 0.05)
            }
            let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
            v = v.map { $0 / max(norm, 1e-6) }
            vectors.append(v)
            builder.accumulate(vector: v)
        }

        let quantizer = builder.build()

        var totalRMSError: Double = 0
        for vector in vectors {
            let encoded = quantizer.encode(vector: vector)
            let decoded = quantizer.decode(bytes: encoded)
            let error = zip(vector, decoded).map { Double($0 - $1) * Double($0 - $1) }.reduce(0, +)
            totalRMSError += sqrt(error / Double(dimensions))
        }
        let avgRMSError = totalRMSError / Double(vectors.count)
        XCTAssertLessThan(avgRMSError, 0.01, "Average RMS error should be < 0.01")
    }

    func test_distancePreservation_quantizedDotProduct_within5Percent() {
        let dimensions = 128
        var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        var vectors: [[Float]] = []
        for _ in 0..<200 {
            var v = (0..<dimensions).map { _ in Float.random(in: -1...1) }
            let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
            v = v.map { $0 / max(norm, 1e-6) }
            vectors.append(v)
            builder.accumulate(vector: v)
        }
        let quantizer = builder.build()

        var query = (0..<dimensions).map { _ in Float.random(in: -1...1) }
        let qNorm = sqrt(query.map { $0 * $0 }.reduce(0, +))
        query = query.map { $0 / max(qNorm, 1e-6) }

        var maxAbsoluteError: Float = 0
        for i in 0..<vectors.count {
            let vector = vectors[i]
            let quantized = quantizer.encode(vector: vector)
            let fullPrecisionDot = vector.withUnsafeBufferPointer { vBuf in
                query.withUnsafeBufferPointer { qBuf in
                    var dot: Float = 0
                    for j in 0..<dimensions {
                        dot += qBuf[j] * vBuf[j]
                    }
                    return dot
                }
            }
            let quantizedDot = quantized.withUnsafeBufferPointer { buf in
                quantizer.quantizedDotProduct(query: query, bytes: buf)
            }
            let absoluteError = abs(fullPrecisionDot - quantizedDot)
            maxAbsoluteError = max(maxAbsoluteError, absoluteError)
        }
        XCTAssertLessThan(maxAbsoluteError, 0.05, "Asymmetric quantized dot product should be close to full-precision")
    }
    func test_boundary_flatDimension() {
        let dimensions = 4
        var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        let vector: [Float] = [1.0, 2.0, 3.0, 3.0]
        builder.accumulate(vector: vector)
        builder.accumulate(vector: vector)
        let quantizer = builder.build()

        let encoded = quantizer.encode(vector: vector)
        XCTAssertEqual(encoded[3], 0, "Flat dimension should encode to 0")

        let decoded = quantizer.decode(bytes: encoded)
        XCTAssertEqual(decoded[3], 3.0, accuracy: 0.001, "Flat dimension should decode back to original value")
    }

    func test_boundary_zeroVector() {
        let dimensions = 4
        var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        let vector: [Float] = [0.0, 0.0, 0.0, 0.0]
        builder.accumulate(vector: vector)
        let quantizer = builder.build()

        let encoded = quantizer.encode(vector: vector)
        XCTAssertEqual(encoded, [0, 0, 0, 0], "Zero vector should encode to all zeros")

        let decoded = quantizer.decode(bytes: encoded)
        XCTAssertEqual(decoded, [0.0, 0.0, 0.0, 0.0], "Zero vector should decode back to zeros")
    }

    func test_boundary_negativeValues() {
        let dimensions = 3
        var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        // Accumulate multiple vectors to establish a real range per dimension
        builder.accumulate(vector: [-2.0, -1.0, -3.0])
        builder.accumulate(vector: [ 0.0,  0.5,  0.0])
        builder.accumulate(vector: [ 1.0,  1.0,  2.0])
        let quantizer = builder.build()

        let vector: [Float] = [-1.0, -0.5, -2.0]
        let encoded = quantizer.encode(vector: vector)
        // With mins=[-2,-1,-3] and maxs=[1,1,2], scales should be non-zero
        XCTAssertNotEqual(encoded, [0, 0, 0], "Negative values with range should encode to non-zero bytes")

        let decoded = quantizer.decode(bytes: encoded)
        XCTAssertEqual(decoded[0], -1.0, accuracy: 0.1)
        XCTAssertEqual(decoded[1], -0.5, accuracy: 0.1)
        XCTAssertEqual(decoded[2], -2.0, accuracy: 0.1)
    }

    func test_serialization_roundTrip() {
        let dimensions = 8
        var builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        for _ in 0..<10 {
            let v = (0..<dimensions).map { _ in Float.random(in: -1...1) }
            builder.accumulate(vector: v)
        }
        let quantizer = builder.build()

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("quantizer-test-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let handle = try! FileHandle(forWritingTo: tempURL)
        try! quantizer.write(to: handle)
        try! handle.close()

        let data = try! Data(contentsOf: tempURL)
        guard let (readQuantizer, nextOffset) = BurnBarScalarQuantizer.read(from: data, dimensions: dimensions, offset: 0) else {
            XCTFail("Failed to read quantizer from data")
            return
        }

        XCTAssertEqual(nextOffset, 2 * dimensions * MemoryLayout<Float>.size)
        XCTAssertEqual(readQuantizer.mins, quantizer.mins)
        XCTAssertEqual(readQuantizer.scales, quantizer.scales)
    }

    func test_emptyBuilder_producesSafeQuantizer() {
        let dimensions = 4
        let builder = BurnBarScalarQuantizerBuilder(dimensions: dimensions)
        let quantizer = builder.build()

        XCTAssertTrue(quantizer.scales.allSatisfy { $0 == 0 }, "Empty builder should produce zero scales")
        XCTAssertEqual(quantizer.mins, [Float.infinity, Float.infinity, Float.infinity, Float.infinity])

        let vector: [Float] = [1.0, 2.0, 3.0, 4.0]
        let encoded = quantizer.encode(vector: vector)
        XCTAssertEqual(encoded, [0, 0, 0, 0], "Empty builder should encode everything to zero")

        let decoded = quantizer.decode(bytes: encoded)
        // When scales are zero, decode returns mins (which are infinity). This is pathological but safe.
        XCTAssertTrue(decoded.allSatisfy { $0.isInfinite }, "Decoded values should be infinity when builder was empty")
    }
}
