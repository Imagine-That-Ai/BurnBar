import Foundation
import XCTest
@testable import OpenBurnBarCore

/// Cross-platform parity: the Swift cloak must produce byte-identical vectors to
/// the TS shim (tools/openburnbar-mcp-remote/src/embed.ts) for the same key +
/// model, so a Mac/TS-indexed vector ranks identically against an iOS-issued
/// query. Reference heads computed by running cloakVector() with key=0x42*32.
final class PensieveCloakTSParityTests: XCTestCase {
    private let key = Data(repeating: 0x42, count: 32)
    private let dim = 384

    private func basis(_ i: Int) -> [Double] { var v = [Double](repeating: 0, count: dim); v[i] = 1; return v }
    private func ramp() -> [Double] { (0..<dim).map { sin(Double($0) * 0.013) } }

    func test_matchesTSReferenceHeads() {
        let e5 = PensieveVectorCloak.cloak(basis(5), vaultKey: key, modelVersion: "bge-small-en-v1.5")
        let e5Ref: [Double] = [0.022701304567289693, 0.006537578863229806, -0.026736270220641744, -0.0012151386975989675, -0.026879464463398724, 0.8776905243399359]
        for (i, ref) in e5Ref.enumerated() { XCTAssertEqual(e5[i], ref, accuracy: 1e-12, "e5[\(i)]") }

        let e5h = PensieveVectorCloak.cloak(basis(5), vaultKey: key, modelVersion: "hashing-bow-v1")
        let e5hRef: [Double] = [0.024962057620774702, -0.0012100986493098734, 0.01970170194431331, -0.01876288243402278, 0.050834395709711204, 0.8367944634995997]
        for (i, ref) in e5hRef.enumerated() { XCTAssertEqual(e5h[i], ref, accuracy: 1e-12, "e5h[\(i)]") }

        let r = PensieveVectorCloak.cloak(ramp(), vaultKey: key, modelVersion: "bge-small-en-v1.5")
        let rRef: [Double] = [-0.23898929145968037, -0.11076881246373149, -0.0589961271598505, -0.04738614601967985, -0.25144654330066174, -0.3537258732327122]
        for (i, ref) in rRef.enumerated() { XCTAssertEqual(r[i], ref, accuracy: 1e-12, "ramp[\(i)]") }
    }

    /// Full embed→cloak path matches the TS deterministic hashing embedder +
    /// cloak for the same phrase, so chunks the daemon/app seal are recall-
    /// compatible with the published shim and the hosted MCP.
    func test_embedAndCloakMatchesTSReference() {
        let cloaked = PensieveVectorCloak.embedAndCloak(
            "hosted minimax encrypted session search",
            vaultKey: key,
            isQuery: false,
            modelVersion: "hashing-bow-v1"
        ).vector
        let ref: [Double] = [-0.06038318803677569, 0.015806595688146123, -0.01819074005506563, -0.013937252354238351, -0.005114345741968682, 0.03677180389002842]
        for (i, value) in ref.enumerated() { XCTAssertEqual(cloaked[i], value, accuracy: 1e-12, "embedAndCloak[\(i)]") }
    }
}
