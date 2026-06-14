import Foundation
import XCTest
@testable import OpenBurnBar

/// T-AI-03: parsed agent logs entering the local RAG/oracle corpus are tagged
/// with a security provenance/trust tier, and third-party-source chunks are
/// quarantined (skipped) before prompt inclusion.
final class RAGProvenanceQuarantineTests: XCTestCase {

    private func conversation(id: String, sourceType: ConversationSourceType) -> ConversationRecord {
        let now = Date()
        return ConversationRecord(
            id: id,
            provider: .cursor,
            sessionId: id,
            projectName: "P",
            startTime: now,
            endTime: now,
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "T",
            lastAssistantMessage: "",
            fullText: "body",
            indexedAt: now,
            fileModifiedAt: now,
            sourceType: sourceType
        )
    }

    private func result(
        chunkID: String,
        sourceKind: SearchSourceKind,
        snippet: String = "snippet body",
        conversation: ConversationRecord? = nil
    ) -> RetrievalResult {
        let now = Date()
        return RetrievalResult(
            chunkID: chunkID,
            documentID: "doc-\(chunkID)",
            sourceKind: sourceKind,
            sourceID: "src-\(chunkID)",
            provider: .cursor,
            providerRawValue: nil,
            projectName: "P",
            title: "T",
            subtitle: nil,
            snippet: snippet,
            sectionPath: nil,
            startOffset: 0,
            endOffset: snippet.count,
            sourceUpdatedAt: nil,
            indexedAt: now,
            lexicalRank: 1,
            semanticScore: nil,
            rerankScore: 0.9,
            conversation: conversation
        )
    }

    // MARK: - Tier classification

    func test_tier_skillAndAgentDocsAreTrusted() {
        XCTAssertEqual(RAGProvenanceClassifier.tier(for: result(chunkID: "a", sourceKind: .skillDoc)), .trusted)
        XCTAssertEqual(RAGProvenanceClassifier.tier(for: result(chunkID: "b", sourceKind: .agentDoc)), .trusted)
    }

    func test_tier_parsedProviderLogsAreCaution() {
        let r = result(
            chunkID: "c",
            sourceKind: .conversation,
            conversation: conversation(id: "conv-1", sourceType: .providerLog)
        )
        XCTAssertEqual(RAGProvenanceClassifier.tier(for: r), .caution)
    }

    func test_tier_sharedArtifactsAreUntrustedSource() {
        let r = result(chunkID: "d", sourceKind: .sharedArtifact)
        let tier = RAGProvenanceClassifier.tier(for: r)
        XCTAssertEqual(tier, .untrustedSource)
        XCTAssertFalse(tier.isPromptIncludable, "untrusted-source chunks must be quarantined")
    }

    // MARK: - Quarantine in formatPack

    func test_formatPack_quarantinesUntrustedSourceChunks() {
        let included = result(
            chunkID: "keep",
            sourceKind: .conversation,
            snippet: "legitimate log line",
            conversation: conversation(id: "conv-keep", sourceType: .providerLog)
        )
        let quarantined = result(
            chunkID: "drop",
            sourceKind: .sharedArtifact,
            snippet: "third party shared artifact"
        )
        let pack = OpenBurnBarChatEvidenceFormatting.formatPack(
            results: [included, quarantined],
            maxTotalChars: 20_000
        )
        XCTAssertTrue(pack.contains("`keep`"), "caution-tier provider log must be included")
        XCTAssertFalse(pack.contains("`drop`"), "untrusted-source chunk must be quarantined")
        XCTAssertFalse(pack.contains("third party shared artifact"))
        XCTAssertTrue(pack.contains("quarantined"), "the pack must disclose that a chunk was withheld")
    }

    func test_formatPack_tagsTrustTierInBlock() {
        let included = result(
            chunkID: "tiered",
            sourceKind: .conversation,
            conversation: conversation(id: "conv-x", sourceType: .providerLog)
        )
        let pack = OpenBurnBarChatEvidenceFormatting.formatPack(
            results: [included],
            maxTotalChars: 20_000
        )
        XCTAssertTrue(pack.contains("trust_tier: caution"))
        XCTAssertTrue(pack.contains("tier=caution"), "the tier travels inside the untrusted wrapper provenance")
    }
}
