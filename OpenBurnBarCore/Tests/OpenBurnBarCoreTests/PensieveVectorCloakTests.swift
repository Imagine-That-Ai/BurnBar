import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore

final class PensieveVectorCloakTests: XCTestCase {
    private let key = Data(repeating: 0x42, count: 32)
    private let otherKey = Data(repeating: 0x24, count: 32)

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func norm(_ a: [Double]) -> Double { dot(a, a).squareRoot() }

    func test_cloak_isDeterministicForKeyAndModel() {
        let v = PensieveVectorCloak.deterministicEmbed("hosted minimax encrypted search")
        let a = PensieveVectorCloak.cloak(v, vaultKey: key, modelVersion: "bge-small-en-v1.5")
        let b = PensieveVectorCloak.cloak(v, vaultKey: key, modelVersion: "bge-small-en-v1.5")
        XCTAssertEqual(a, b)
    }

    func test_cloak_preservesNormAndInnerProduct_exactly() {
        // Orthonormal Q ⇒ ‖Qx‖ = ‖x‖ and <Qx,Qy> = <x,y>. Cosine ranking is
        // therefore identical over cloaked vs raw vectors — the core invariant.
        let x = PensieveVectorCloak.deterministicEmbed("pensieve repo docs and notes")
        let y = PensieveVectorCloak.deterministicEmbed("repo documentation knowledge memory")

        let qx = PensieveVectorCloak.cloak(x, vaultKey: key)
        let qy = PensieveVectorCloak.cloak(y, vaultKey: key)

        XCTAssertEqual(norm(qx), norm(x), accuracy: 1e-9)
        XCTAssertEqual(norm(qy), norm(y), accuracy: 1e-9)
        XCTAssertEqual(dot(qx, qy), dot(x, y), accuracy: 1e-9)
    }

    func test_cloak_differsByKey() {
        let v = PensieveVectorCloak.deterministicEmbed("private launch plan")
        let a = PensieveVectorCloak.cloak(v, vaultKey: key)
        let b = PensieveVectorCloak.cloak(v, vaultKey: otherKey)
        XCTAssertNotEqual(a, b)
        // But each still preserves the norm.
        XCTAssertEqual(norm(a), norm(v), accuracy: 1e-9)
        XCTAssertEqual(norm(b), norm(v), accuracy: 1e-9)
    }

    func test_deterministicEmbed_isNormalized384Dim() {
        let v = PensieveVectorCloak.deterministicEmbed("alpha beta gamma delta")
        XCTAssertEqual(v.count, PensieveVectorCloak.embeddingDim)
        XCTAssertEqual(norm(v), 1.0, accuracy: 1e-9)
    }

    func test_queryInstructionChangesEmbedding() {
        let doc = PensieveVectorCloak.deterministicEmbed("scaling vector search", isQuery: false)
        let query = PensieveVectorCloak.deterministicEmbed("scaling vector search", isQuery: true)
        XCTAssertNotEqual(doc, query) // bge query instruction prefix is applied
    }
}
