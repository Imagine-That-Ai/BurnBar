// SPDX-License-Identifier: AGPL-3.0-only
//
// Package-lane contract pins for the usage-memory source-kind vocabulary
// (PR1 of the usage-memory program). The app-lane suite
// (OpenBurnBarTests/UsageMemorySourceKindTests) pins the store behavior;
// this file pins the frozen serving-contract vocabulary itself where the
// SwiftPM coverage lane can measure it.

import XCTest
@testable import OpenBurnBarKernel

final class MemorySourceKindContractTests: XCTestCase {
    func testUsageKindsAreExactlyTheTwoPassiveSources() {
        XCTAssertEqual(MemorySourceKind.usageKinds, [.safariAsk, .agentSession])
        XCTAssertFalse(MemorySourceKind.usageKinds.contains(.agent), "agent is member content, chat-partitioned")
        XCTAssertFalse(MemorySourceKind.usageKinds.contains(.chat))
        XCTAssertFalse(MemorySourceKind.usageKinds.contains(.code))
    }

    func testSourceKindRawValuesAreFrozen() {
        // Persisted in the authority table's source_kind column — renames are
        // schema breaks, not refactors.
        XCTAssertEqual(MemorySourceKind.chat.rawValue, "chat")
        XCTAssertEqual(MemorySourceKind.code.rawValue, "code")
        XCTAssertEqual(MemorySourceKind.safariAsk.rawValue, "safari_ask")
        XCTAssertEqual(MemorySourceKind.agentSession.rawValue, "agent_session")
        // Blind sync: the Firestore rules admit this literal on the wire.
        XCTAssertEqual(MemorySourceKind.agent.rawValue, "agent")
    }

    func testProvenanceSourceKindRawValuesAreFrozen() {
        // Persisted in memory_provenance.source_kind — a per-citation
        // namespace deliberately distinct from MemorySourceKind (existing
        // chat rows store "chat_message", not "chat").
        XCTAssertEqual(MemoryProvenanceSourceKind.chatMessage.rawValue, "chat_message")
        XCTAssertEqual(MemoryProvenanceSourceKind.safariAsk.rawValue, "safari_ask")
        XCTAssertEqual(MemoryProvenanceSourceKind.agentSessionEvent.rawValue, "agent_session_event")
    }
}
