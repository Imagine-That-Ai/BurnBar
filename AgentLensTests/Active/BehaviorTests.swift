import XCTest
@testable import OpenBurnBar

/// C3 — the Swift behavior interpreter. When the TS core's golden vectors
/// (`packages/petcore/test/golden/behavior.json`) are present they are consumed
/// for same-seed parity; otherwise the suite asserts the interpreter's own
/// determinism + weighted-selection contract, which is what the golden vectors
/// will later pin.
final class BehaviorTests: XCTestCase {

    // MARK: Graph fixtures

    private func makeGraph() -> PetBehaviorGraph {
        PetBehaviorGraph(
            initial: "idle",
            transitions: [
                .init(from: "idle", to: "wander", when: .cooldownElapsed, weight: 12),
                .init(from: "idle", to: "react", when: .special, weight: 1),
                .init(from: "idle", to: "listen", when: .cursorNear, weight: 100),
                .init(from: "listen", to: "think", when: .sendPressed, weight: nil),
                .init(from: "think", to: "speak", when: .streamStart, weight: nil),
                .init(from: "speak", to: "react", when: .fallbackFired, weight: nil)
            ]
        )
    }

    // MARK: Determinism

    func test_sameSeed_producesIdenticalSequence() {
        let graph = makeGraph()
        let triggers: [PetBehaviorTrigger] = [.cursorNear, .sendPressed, .streamStart, .fallbackFired]

        func run(seed: UInt32) -> [String] {
            var interp = BehaviorInterpreter(graph: graph, seed: seed)
            return triggers.compactMap { interp.fire($0) }
        }

        XCTAssertEqual(run(seed: 42), run(seed: 42))
        XCTAssertEqual(run(seed: 42), ["listen", "think", "speak", "react"])
    }

    func test_singleCandidate_isDeterministicRegardlessOfSeed() {
        let graph = makeGraph()
        // from "listen" only one transition matches sendPressed → think.
        for seed: UInt32 in [1, 7, 99, 123_456] {
            var interp = BehaviorInterpreter(graph: graph, seed: seed)
            _ = interp.fire(.cursorNear) // idle → listen
            XCTAssertEqual(interp.fire(.sendPressed), "think")
        }
    }

    func test_noMatchingTransition_staysPut() {
        let graph = makeGraph()
        var interp = BehaviorInterpreter(graph: graph, seed: 1)
        XCTAssertNil(interp.fire(.streamStart)) // idle has no streamStart edge
        XCTAssertEqual(interp.current, "idle")
    }

    func test_reset_returnsToInitial() {
        let graph = makeGraph()
        var interp = BehaviorInterpreter(graph: graph, seed: 1)
        _ = interp.fire(.cursorNear)
        XCTAssertEqual(interp.current, "listen")
        interp.reset()
        XCTAssertEqual(interp.current, "idle")
    }

    // MARK: Weighted selection

    func test_weightedSelection_favoursHeavyEdge() {
        // Two edges from idle on the SAME trigger with lopsided weights.
        let graph = PetBehaviorGraph(
            initial: "idle",
            transitions: [
                .init(from: "idle", to: "heavy", when: .cooldownElapsed, weight: 95),
                .init(from: "idle", to: "light", when: .cooldownElapsed, weight: 5)
            ]
        )
        var heavy = 0
        let trials = 2000
        for seed in 0..<trials {
            var interp = BehaviorInterpreter(graph: graph, seed: UInt32(seed) | 1)
            if interp.fire(.cooldownElapsed) == "heavy" { heavy += 1 }
        }
        let ratio = Double(heavy) / Double(trials)
        // ~0.95 expected; allow generous tolerance for the sampling.
        XCTAssertGreaterThan(ratio, 0.85, "heavy edge should dominate (got \(ratio))")
    }

    // MARK: Mulberry32 determinism

    func test_mulberry32_isDeterministicAndStable() {
        var a = Mulberry32(seed: 1)
        var b = Mulberry32(seed: 1)
        for _ in 0..<10 {
            XCTAssertEqual(a.nextUInt32(), b.nextUInt32())
        }
        // Pin the first value for seed 1 so a refactor can't silently drift the
        // sequence the golden vectors will rely on.
        var c = Mulberry32(seed: 1)
        XCTAssertEqual(c.nextUInt32(), 2_693_262_067)
    }

    // MARK: Golden-vector parity (consumed if the TS export exists)

    func test_goldenVectors_matchWhenPresent() throws {
        guard let data = Self.loadGoldenVectorData() else {
            throw XCTSkip("petcore golden behavior-swift.json not present; determinism covered above")
        }
        let vector = try JSONDecoder().decode(BehaviorGoldenVector.self, from: data)
        var interp = BehaviorInterpreter(graph: vector.graph, seed: vector.seed)
        for (i, step) in vector.steps.enumerated() {
            let produced = interp.fire(step.trigger)
            XCTAssertEqual(produced, step.expected,
                           "golden step \(i) trigger=\(step.trigger.rawValue)")
        }
    }

    /// Look for an opt-in Swift-compatible golden file. The shared TS petcore
    /// export currently uses a different multi-seed shape, so this deliberately
    /// avoids hard-coded machine-local paths and skips unless a converted fixture
    /// is provided.
    private static func loadGoldenVectorData() -> Data? {
        let environment = ProcessInfo.processInfo.environment
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            environment["OPENBURNBAR_PET_BEHAVIOR_GOLDEN_JSON"],
            repoRoot
                .appendingPathComponent("packages/petcore/test/golden/behavior-swift.json")
                .path
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return data
            }
        }
        return nil
    }
}
