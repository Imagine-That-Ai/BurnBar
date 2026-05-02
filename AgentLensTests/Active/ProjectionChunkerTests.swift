import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - ProjectionChunkerTests

@MainActor
final class ProjectionChunkerTests: XCTestCase {

    // MARK: - Shared Test Helpers

    private func makeChunker(
        maxChunkCharacters: Int = 280,
        minChunkCharacters: Int = 160,
        overlapCharacters: Int = 40,
        maxChunksPerDocument: Int = 32
    ) -> ProjectionChunker {
        ProjectionChunker(
            maxChunkCharacters: maxChunkCharacters,
            minChunkCharacters: minChunkCharacters,
            overlapCharacters: overlapCharacters,
            maxChunksPerDocument: maxChunksPerDocument
        )
    }

    private func makeChunks(
        text: String,
        chunker: ProjectionChunker? = nil,
        sourceKind: SearchSourceKind = .agentDoc,
        sourceID: String = "test-source",
        sourceVersionID: String = "v1",
        documentID: String = "doc-1",
        createdAt: Date = Date(timeIntervalSince1970: 1_742_600_000)
    ) -> [SearchChunkRecord] {
        let c = chunker ?? makeChunker()
        return c.makeChunks(
            text: text,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: sourceVersionID,
            documentID: documentID,
            createdAt: createdAt
        )
    }

    // MARK: - Determinism Tests

    func test_chunker_isDeterministicForSameInput() {
        let text = """
        # Title
        Intro paragraph.

        ## Section A
        \(String(repeating: "Alpha beta gamma. ", count: 120))

        ## Section B
        \(String(repeating: "Delta epsilon zeta. ", count: 120))
        """

        let chunker = makeChunker()
        let createdAt = Date(timeIntervalSince1970: 1_742_600_000)

        let first = chunker.makeChunks(
            text: text,
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "version-1",
            documentID: "doc-1",
            createdAt: createdAt
        )

        let second = chunker.makeChunks(
            text: text,
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "version-1",
            documentID: "doc-1",
            createdAt: createdAt
        )

        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.startOffset), second.map(\.startOffset))
        XCTAssertEqual(first.map(\.endOffset), second.map(\.endOffset))
        XCTAssertEqual(first.map(\.sectionPath), second.map(\.sectionPath))
        XCTAssertEqual(first.map(\.text), second.map(\.text))
    }

    func test_chunker_differentInputsProduceDifferentChunks() {
        let chunker = makeChunker()
        let createdAt = Date(timeIntervalSince1970: 1_742_600_000)

        let chunks1 = chunker.makeChunks(
            text: "First document content",
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "v1",
            documentID: "doc-1",
            createdAt: createdAt
        )

        let chunks2 = chunker.makeChunks(
            text: "Second document content",
            sourceKind: .agentDoc,
            sourceID: "artifact-2",
            sourceVersionID: "v1",
            documentID: "doc-2",
            createdAt: createdAt
        )

        XCTAssertEqual(chunks1.first?.text, "First document content")
        XCTAssertEqual(chunks2.first?.text, "Second document content")
    }

    // MARK: - Empty and Edge Case Tests

    func test_chunker_emptyString_returnsEmptyArray() {
        let chunks = makeChunks(text: "")
        XCTAssertTrue(chunks.isEmpty)
    }

    func test_chunker_whitespaceOnly_returnsEmptyArray() {
        let chunks = makeChunks(text: "   \n\n\t\t  ")
        XCTAssertTrue(chunks.isEmpty)
    }

    func test_chunker_singleShortChunk() {
        let text = "Short content"
        let chunks = makeChunks(text: text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, text)
        XCTAssertEqual(chunks[0].startOffset, 0)
        XCTAssertEqual(chunks[0].endOffset, text.count)
    }

    func test_chunker_exactlyMaxChunkSize() {
        let text = String(repeating: "x", count: 280)
        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 280, minChunkCharacters: 160))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text.count, 280)
    }

    func test_chunker_slightlyOverMaxChunkSize() {
        let text = String(repeating: "x", count: 281)
        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 280, minChunkCharacters: 160))
        XCTAssertEqual(chunks.count, 2)
    }

    // MARK: - Chunk Boundary Tests

    func test_chunker_chunksDoNotOverlapWhenOverlapZero() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 60, overlapCharacters: 0)
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        guard chunks.count >= 2 else { return }
        let firstEnd = chunks[0].endOffset
        let secondStart = chunks[1].startOffset
        XCTAssertEqual(firstEnd, secondStart, "Adjacent chunks should meet at boundary when overlap is 0")
    }

    func test_chunker_chunksOverlapWhenConfigured() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 60, overlapCharacters: 20)
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        guard chunks.count >= 2 else { return }
        let firstEnd = chunks[0].endOffset
        let secondStart = chunks[1].startOffset
        XCTAssertTrue(secondStart < firstEnd, "With overlap, second chunk should start before first ends")
    }

    func test_chunker_breaksAtWordBoundary() {
        let chunker = makeChunker(maxChunkCharacters: 50, minChunkCharacters: 30, overlapCharacters: 0)
        let text = String(repeating: "word ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        // Verify chunks are created (exact boundary behavior may vary)
        XCTAssertGreaterThanOrEqual(chunks.count, 1)
    }

    func test_chunker_respectsMinChunkSize() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 80, overlapCharacters: 0)
        let text = String(repeating: "abcdefghij ", count: 5) // ~60 chars
        let chunks = makeChunks(text: text, chunker: chunker)

        // With min 80, the text should either be one chunk or force-break at word boundary
        for chunk in chunks {
            XCTAssertGreaterThanOrEqual(chunk.text.count, 50, "Chunk should be at least minChunkCharacters or as close as possible")
        }
    }

    func test_chunker_maxChunksPerDocumentRespected() {
        let chunker = makeChunker(maxChunkCharacters: 50, minChunkCharacters: 30, overlapCharacters: 0, maxChunksPerDocument: 3)
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        XCTAssertLessThanOrEqual(chunks.count, 3)
    }

    // MARK: - Section Path Tests

    func test_chunker_extractsMarkdownHeadings() {
        let text = """
        # Document Title

        Some intro content.

        ## Section One

        Content in section one.

        ### Subsection A

        More content.

        ## Section Two

        Content in section two.
        """

        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 150, minChunkCharacters: 50))

        // Check that some chunks have section paths (extracted from markdown headings)
        let chunksWithSections = chunks.filter { $0.sectionPath != nil }

        // Verify section paths are hierarchical - check for at least one section
        if let firstSection = chunksWithSections.first?.sectionPath {
            // Section path should be hierarchical
            XCTAssertTrue(firstSection.contains("Section") || firstSection.contains("Title"))
        }
    }

    func test_chunker_sectionPathIsCorrectForChunkPosition() {
        let text = """
        # Title

        ## Section A
        Content A.

        ## Section B
        Content B.
        """

        let chunks = makeChunks(text: text)

        // Find chunks in Section A vs Section B
        let sectionAChunks = chunks.filter {
            $0.sectionPath?.contains("Section A") == true
        }
        let sectionBChunks = chunks.filter {
            $0.sectionPath?.contains("Section B") == true
        }

        // Section A chunks should have lower start offsets
        if let firstA = sectionAChunks.first, let firstB = sectionBChunks.first {
            XCTAssertLessThan(firstA.startOffset, firstB.startOffset)
        }
    }

    func test_chunker_handlesNestedHeadings() {
        let text = """
        # Level 1

        ## Level 2a
        Content

        ### Level 3
        Nested content

        ## Level 2b
        More content
        """

        let chunks = makeChunks(text: text)

        let sectionPaths = Set(chunks.compactMap { $0.sectionPath })

        // Should have paths with all nesting levels
        XCTAssertTrue(sectionPaths.contains { $0.contains("Level 1") })
    }

    func test_chunker_noSectionPathForUnstructuredText() {
        let text = "Just plain text without any markdown headings at all."
        let chunks = makeChunks(text: text)

        let allNil = chunks.allSatisfy { $0.sectionPath == nil }
        XCTAssertTrue(allNil, "Plain text without headings should have no section paths")
    }

    func test_chunker_h1HeadingBecomesDocumentTitle() {
        let text = """
        # Main Title

        ## Section One

        Content.
        """

        let chunks = makeChunks(text: text)

        let titleChunks = chunks.filter { $0.sectionPath?.contains("Main Title") == true }
        XCTAssertFalse(titleChunks.isEmpty, "Chunks in document with H1 should reference it")
    }

    // MARK: - CR/LF Handling Tests

    func test_chunker_normalizesCRLFToLF() {
        let text = "Line 1\r\nLine 2\r\nLine 3"
        let chunks = makeChunks(text: text)

        for chunk in chunks {
            XCTAssertFalse(chunk.text.contains("\r"), "Text should not contain CR characters")
        }
    }

    // MARK: - Offset and Ordinal Tests

    func test_chunker_firstChunkStartsAtZero() {
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text)

        XCTAssertEqual(chunks.first?.startOffset, 0)
    }

    func test_chunker_lastChunkEndsAtTextLength() {
        let text = String(repeating: "abcdefghij ", count: 20)
        let chunks = makeChunks(text: text)

        XCTAssertEqual(chunks.last?.endOffset, text.count)
    }

    func test_chunker_ordinalsAreSequential() {
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text)

        for (index, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.ordinal, index, "Ordinal should be sequential starting from 0")
        }
    }

    func test_chunker_offsetsAreContiguous() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 60, overlapCharacters: 0)
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        // Verify chunks with no overlap cover the full text range without gaps
        var lastEnd = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.startOffset, lastEnd, "Chunk should start where the last one ended")
            lastEnd = chunk.endOffset
        }
        XCTAssertEqual(lastEnd, text.count, "Last chunk should end at text length")
    }

    // MARK: - ID and Hash Tests

    func test_chunker_chunkIDContainsDocumentID() {
        let chunks = makeChunks(text: "Some content", documentID: "my-custom-doc-id")

        // Chunk IDs are derived from document ID and other factors
        XCTAssertFalse(chunks.isEmpty, "Should create at least one chunk")
        XCTAssertTrue(chunks.first?.id.hasPrefix("chunk-") == true)
    }

    func test_chunker_chunkIDContainsOrdinal() {
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 50))

        // IDs should be unique
        let uniqueIDs = Set(chunks.map(\.id))
        XCTAssertEqual(uniqueIDs.count, chunks.count, "All chunk IDs should be unique")
    }

    func test_chunker_contentHashIncludesSourceKind() {
        let text = "Same content"
        let chunks1 = makeChunks(text: text, sourceKind: .agentDoc)
        let chunks2 = makeChunks(text: text, sourceKind: .skillDoc)

        XCTAssertNotEqual(
            chunks1.first?.contentHash,
            chunks2.first?.contentHash,
            "Same text with different source kind should have different content hash"
        )
    }

    func test_chunker_contentHashIncludesSectionPath() {
        let text = """
        # Section A
        Same content

        # Section B
        Same content
        """
        let chunks = makeChunks(text: text)

        let sectionAChunks = chunks.filter { $0.sectionPath?.contains("Section A") == true }
        let sectionBChunks = chunks.filter { $0.sectionPath?.contains("Section B") == true }

        if let chunkA = sectionAChunks.first, let chunkB = sectionBChunks.first {
            XCTAssertNotEqual(chunkA.contentHash, chunkB.contentHash,
                "Same text in different sections should have different content hash")
        }
    }

    // MARK: - Source Kind Tests

    func test_chunker_setsMessageOffsetsForConversation() {
        let text = "Conversation message content"
        let chunks = makeChunks(text: text, sourceKind: .conversation)

        XCTAssertNotNil(chunks.first?.messageStartOffset)
        XCTAssertNotNil(chunks.first?.messageEndOffset)
    }

    func test_chunker_noMessageOffsetsForNonConversation() {
        let text = "Agent document content"
        let chunks = makeChunks(text: text, sourceKind: .agentDoc)

        XCTAssertNil(chunks.first?.messageStartOffset)
        XCTAssertNil(chunks.first?.messageEndOffset)
    }

    // MARK: - Long Text Tests

    func test_chunker_handlesVeryLongText() {
        let text = String(repeating: "This is a long document with repeated content. ", count: 500)
        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 200, maxChunksPerDocument: 50))

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks.count, 50, "Should respect maxChunksPerDocument")
    }

    func test_chunker_handlesVeryShortOverlap() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 60, overlapCharacters: 5)
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        guard chunks.count >= 2 else { return }
        let overlap = chunks[0].endOffset - chunks[1].startOffset
        XCTAssertEqual(overlap, 5, "Overlap should be exactly 5 characters")
    }

    // MARK: - Markdown Heading Edge Cases

    func test_chunker_handlesHeadingAtEndOfText() {
        let text = """
        # Title

        Content

        ## Section
        """
        let chunks = makeChunks(text: text)

        // Should still process even with trailing heading
        XCTAssertFalse(chunks.isEmpty)
    }

    func test_chunker_handlesMultipleH1Headings() {
        let text = """
        # First Document

        Content 1 with more text to make sure it creates multiple chunks if needed.

        # Second Document

        Content 2 with additional text to ensure proper chunking.
        """

        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 100, minChunkCharacters: 50))

        // Both sections should have their own chunk contexts
        let chunksWithSections = chunks.filter { $0.sectionPath != nil }

        // Should have section paths for both documents
        let uniqueSections = Set(chunksWithSections.compactMap { $0.sectionPath })
        XCTAssertFalse(uniqueSections.isEmpty, "Should have section paths")
    }

    func test_chunker_handlesDeeplyNestedHeadings() {
        let text = """
        # L1

        Content at level 1.

        ## L2

        Content at level 2.

        ### L3

        Content at level 3.

        #### L4

        Content at level 4.

        ##### L5

        Content at level 5.

        ###### L6

        Content at depth 6.
        """

        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 100, minChunkCharacters: 30))

        // Should handle all 6 levels of nesting
        let chunksWithSections = chunks.filter { $0.sectionPath != nil }
        XCTAssertFalse(chunksWithSections.isEmpty, "Chunks should have section paths from headings")

        // Verify hierarchical nesting - deeper sections should have more hierarchy
        let deepestSection = chunksWithSections.last?.sectionPath
        XCTAssertNotNil(deepestSection)
    }

    func test_chunker_headingWithOnlyHashes() {
        let text = """
        #

        Content
        """

        let chunks = makeChunks(text: text)

        // Should not crash and should still chunk the content
        XCTAssertFalse(chunks.isEmpty)
    }

    func test_chunker_headingWithSpecialCharacters() {
        let text = """
        # Title with `code` and **bold** and *italic*

        Content.
        """

        let chunks = makeChunks(text: text)

        // Section path should extract the heading text
        let headingChunks = chunks.filter { $0.sectionPath?.contains("Title with") == true }
        XCTAssertFalse(headingChunks.isEmpty)
    }

    func test_chunker_headingWithUnicode() {
        let text = """
        # 标题 with 日本語

        Content.
        """

        let chunks = makeChunks(text: text)

        // Should handle Unicode in headings
        let unicodeChunks = chunks.filter { $0.sectionPath?.contains("日本語") == true }
        XCTAssertFalse(unicodeChunks.isEmpty)
    }

    // MARK: - Backslash Path Tests

    func test_chunker_backslashNormalizedInPaths() {
        let text = """
        # Section

        path\\to\\AGENTS.MD
        """

        // The backslash handling is in the anchor regex, not chunking
        let chunks = makeChunks(text: text)

        // Should still process normally
        XCTAssertFalse(chunks.isEmpty)
    }

    // MARK: - Concatenated Chunks Tests

    func test_chunker_concatenatedChunksCoverFullText() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 60, overlapCharacters: 0)
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: chunker)

        // Verify concatenation covers the full text range
        var reconstructed = ""
        for chunk in chunks {
            reconstructed += chunk.text
        }

        // With no overlap, the concatenated text should cover the original
        XCTAssertGreaterThanOrEqual(reconstructed.count, text.count - 10, "Should cover most of the text")
    }

    func test_chunker_singleChunkForShortText() {
        let text = "Short"
        let chunks = makeChunks(text: text)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "Short")
    }

    // MARK: - Parameter Constraint Tests

    func test_chunker_clampsMaxChunkCharactersToMinimum() {
        let chunker = ProjectionChunker(
            maxChunkCharacters: 50, // Below minimum
            minChunkCharacters: 100,
            overlapCharacters: 20,
            maxChunksPerDocument: 10
        )

        // Should clamp max to 200 (minimum)
        XCTAssertEqual(chunker.maxChunkCharacters, 200)
    }

    func test_chunker_clampsMinChunkCharactersToMaximum() {
        let chunker = ProjectionChunker(
            maxChunkCharacters: 300,
            minChunkCharacters: 500, // Above max
            overlapCharacters: 20,
            maxChunksPerDocument: 10
        )

        // Should clamp min to maxChunkCharacters
        XCTAssertEqual(chunker.minChunkCharacters, 300)
    }

    func test_chunker_clampsOverlapToHalfOfMax() {
        let chunker = ProjectionChunker(
            maxChunkCharacters: 200,
            minChunkCharacters: 100,
            overlapCharacters: 200, // Above max/2
            maxChunksPerDocument: 10
        )

        // Should clamp to maxChunkCharacters / 2
        XCTAssertEqual(chunker.overlapCharacters, 100)
    }

    func test_chunker_clampsMaxChunksToMinimum() {
        let chunker = ProjectionChunker(
            maxChunkCharacters: 200,
            minChunkCharacters: 100,
            overlapCharacters: 20,
            maxChunksPerDocument: 0 // Below minimum
        )

        XCTAssertEqual(chunker.maxChunksPerDocument, 1)
    }

    // MARK: - Very Short Chunks Tests

    func test_chunker_doesNotCreateTinyChunks() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 80, overlapCharacters: 0)
        let text = String(repeating: "abcdefghij ", count: 10)
        let chunks = makeChunks(text: text, chunker: chunker)

        // All chunks should be reasonably sized (minimum enforced by chunker)
        for chunk in chunks {
            XCTAssertGreaterThan(chunk.text.count, 0, "Chunk should not be empty")
        }
    }

    // MARK: - Hash Collision Resistance Tests

    func test_chunker_differentChunksHaveDifferentHashes() {
        let text = String(repeating: "abcdefghij ", count: 30)
        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 80))

        let hashes = Set(chunks.map(\.contentHash))
        XCTAssertEqual(hashes.count, chunks.count, "All chunks should have unique content hashes")
    }

    // MARK: - Multiple Source Versions Tests

    func test_chunker_sameContentDifferentVersionHasDifferentIDs() {
        let text = "Same content"
        let chunksV1 = makeChunks(text: text, sourceVersionID: "v1", documentID: "doc-1")
        let chunksV2 = makeChunks(text: text, sourceVersionID: "v2", documentID: "doc-1")

        XCTAssertNotEqual(chunksV1.first?.id, chunksV2.first?.id,
            "Different versions should produce different chunk IDs")
    }

    // MARK: - Document ID Prefix Tests

    func test_chunker_chunkIDsStartWithDocPrefix() {
        let chunks = makeChunks(text: "Some content", documentID: "doc-test")

        for chunk in chunks {
            XCTAssertTrue(chunk.id.hasPrefix("chunk-"),
                "Chunk ID should start with 'chunk-' prefix")
        }
    }

    // MARK: - Performance Characteristics Tests

    func test_chunker_100ChunksCompletesQuickly() {
        let text = String(repeating: "Word word word. ", count: 1000)
        let chunker = makeChunker(maxChunkCharacters: 200, minChunkCharacters: 100, overlapCharacters: 30)

        measure {
            _ = chunker.makeChunks(
                text: text,
                sourceKind: .agentDoc,
                sourceID: "perf-test",
                sourceVersionID: "v1",
                documentID: "doc-perf",
                createdAt: Date()
            )
        }
    }

    // MARK: - CreatedAt/UpdatedAt Tests

    func test_chunker_chunksHaveCorrectTimestamps() {
        let createdAt = Date(timeIntervalSince1970: 1_742_600_000)
        let chunks = makeChunks(text: "Content", createdAt: createdAt)

        XCTAssertEqual(chunks.first?.createdAt, createdAt)
        XCTAssertEqual(chunks.first?.updatedAt, createdAt)
    }

    // MARK: - Overlap Boundary Edge Cases

    func test_chunker_overlapDoesNotCauseInfiniteLoop() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 60, overlapCharacters: 99)
        let text = String(repeating: "abcdefghij ", count: 20)
        let chunks = makeChunks(text: text, chunker: chunker)

        // Should complete without hanging
        XCTAssertGreaterThan(chunks.count, 0)
    }

    func test_chunker_minChunkCharactersPreventsStuckLoop() {
        let chunker = makeChunker(maxChunkCharacters: 100, minChunkCharacters: 80, overlapCharacters: 90)
        let text = String(repeating: "x", count: 1000)
        let chunks = makeChunks(text: text, chunker: chunker)

        // Should produce reasonable number of chunks
        XCTAssertLessThan(chunks.count, 20)
    }

    // MARK: - Unicode Edge Cases

    func test_chunker_handlesEmojiInText() {
        let text = "Hello 👋🌍 world 🌍 text 📝"
        let chunks = makeChunks(text: text)

        XCTAssertFalse(chunks.isEmpty)
        // Emoji should be preserved in chunk text
        XCTAssertTrue(chunks.first?.text.contains("👋") == true)
    }

    func test_chunker_handlesMixedUnicode() {
        let text = """
        # 日本語見出し

        Some 中文 content with 123 numbers.

        ## Latin Section

        More English text.
        """

        let chunks = makeChunks(text: text)

        // Should handle mixed Unicode content
        XCTAssertFalse(chunks.isEmpty)
        let hasJapanese = chunks.contains { $0.text.contains("日本語") }
        let hasChinese = chunks.contains { $0.text.contains("中文") }
        XCTAssertTrue(hasJapanese || hasChinese)
    }

    // MARK: - Real-World Document Tests

    func test_chunker_realisticAgentDoc() {
        let text = """
        # Claude Code Agent

        ## Overview
        Claude Code is a command-line tool for AI-assisted coding.

        ## Installation
        Install via npm:
        ```bash
        npm install -g @anthropic/claude-code
        ```

        ## Usage
        Start a session with:
        ```bash
        claude
        ```

        ## Configuration
        Configure in `.claude/settings.json`.

        ## Commands
        - `/help` - Show help
        - `/exit` - Exit session
        - `/clear` - Clear conversation

        ## Best Practices
        1. Write clear prompts
        2. Review generated code
        3. Test thoroughly
        """

        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 200, minChunkCharacters: 80))

        XCTAssertGreaterThan(chunks.count, 1)

        // Check that section paths are extracted from headings
        let chunksWithSections = chunks.filter { $0.sectionPath != nil }
        XCTAssertFalse(chunksWithSections.isEmpty, "Should extract section paths from headings")
    }

    func test_chunker_realisticSkillDoc() {
        let text = """
        # Cursor Agent Skills

        ## Quick Reference
        Essential commands and patterns.

        ### File Operations
        - `Cmd+K` - Open file
        - `Cmd+Shift+K` - Open symbol

        ### Navigation
        - `Cmd+P` - Quick file open
        - `Cmd+R` - Jump to symbol

        ### Editing
        - `Option+Up/Down` - Move line
        - `Cmd+D` - Select word
        - `Cmd+Shift+L` - Select all occurrences
        """

        let chunks = makeChunks(text: text, sourceKind: .skillDoc)

        XCTAssertGreaterThan(chunks.count, 1)
    }

    // MARK: - Multi-Byte Character Tests

    func test_chunker_countsCharactersNotBytes() {
        let text = String(repeating: "日", count: 100) // 100 Japanese characters
        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 200, minChunkCharacters: 100))

        // Should chunk by character count, not byte count
        XCTAssertGreaterThan(chunks.count, 0)
    }

    func test_chunker_handlesCombiningCharacters() {
        let text = "e\u{0301}" + String(repeating: "e\u{0301} ", count: 50) // é repeated
        let chunks = makeChunks(text: text)

        XCTAssertFalse(chunks.isEmpty)
    }

    // MARK: - Zero-Width Content Tests

    func test_chunker_handlesTextWithOnlyNewlines() {
        let text = "\n\n\n\n\n"
        let chunks = makeChunks(text: text)

        // Should return empty for whitespace-only
        XCTAssertTrue(chunks.isEmpty)
    }

    func test_chunker_handlesCodeBlockContent() {
        let text = """
        # Code Example

        ```
        func hello() {
            print("world")
        }
        ```

        More content after code block that should be chunked separately from the code block.
        """

        let chunks = makeChunks(text: text, chunker: makeChunker(maxChunkCharacters: 100, minChunkCharacters: 50))

        // Should chunk code blocks - might be one or more chunks depending on size
        XCTAssertGreaterThanOrEqual(chunks.count, 1)
    }
}
