import XCTest
@testable import OpenBurnBar

final class ChatStreamingMessageMutationTests: XCTestCase {

    private enum StreamTestError: Error {
        case interrupted
    }

    func testChatMessageRecord_contentIsMutable() {
        var record = ChatMessageRecord(role: .assistant, content: "Hello")
        record.content.append(", world")
        XCTAssertEqual(record.content, "Hello, world")
    }

    func testChatMessageRecord_transcriptPiecesIsMutable() {
        var record = ChatMessageRecord(role: .assistant, content: "")
        record.transcriptPieces.append(ChatTranscriptPiece(kind: .text, value: "first"))
        record.transcriptPieces.append(ChatTranscriptPiece(kind: .text, value: " second"))
        XCTAssertEqual(record.transcriptPieces.count, 2)
    }

    func testChatMessageRecord_joinedTextExcludesLabeledReasoningAndRefusal() {
        let pieces = [
            ChatTranscriptPiece(kind: .reasoning, value: "private chain scratchpad"),
            ChatTranscriptPiece(kind: .text, value: "Safe answer."),
            ChatTranscriptPiece(kind: .refusal, value: "I cannot help with that.")
        ]

        XCTAssertEqual(ChatMessageRecord.joinedText(from: pieces), "Safe answer.")
    }

    func testChatMessageRecord_codablePreservesLabeledTranscriptPieces() throws {
        let record = ChatMessageRecord(
            id: "assistant-labeled",
            role: .assistant,
            content: "Safe answer.",
            transcriptPieces: [
                ChatTranscriptPiece(id: "r1", kind: .reasoning, value: "thinking"),
                ChatTranscriptPiece(id: "t1", kind: .text, value: "Safe answer."),
                ChatTranscriptPiece(id: "f1", kind: .refusal, value: "No.")
            ]
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ChatMessageRecord.self, from: data)

        XCTAssertEqual(decoded.transcriptPieces.map(\.kind), [.reasoning, .text, .refusal])
        XCTAssertEqual(decoded.displayTranscript[0].value, "thinking")
    }

    func testChatMessageRecord_arrayMutationInPlace() {
        var records: [ChatMessageRecord] = [
            ChatMessageRecord(role: .user, content: "Q"),
            ChatMessageRecord(role: .assistant, content: "")
        ]
        records[1].content.append("partial answer")
        records[1].content.append(" more")
        XCTAssertEqual(records[1].content, "partial answer more")
    }

    func testChatMessageRecord_idsAreStableUnderContentMutation() {
        let originalID = "stable-id"
        var record = ChatMessageRecord(id: originalID, role: .assistant, content: "")
        record.content.append("chunk-1")
        record.content.append("chunk-2")
        XCTAssertEqual(record.id, originalID)
        XCTAssertEqual(record.content, "chunk-1chunk-2")
    }

    func testChatMessageRecord_otherFieldsRemainImmutable() {
        let timestamp = Date()
        var record = ChatMessageRecord(
            id: "x",
            role: .assistant,
            content: "",
            timestamp: timestamp,
            cliUsed: "claude",
            attachments: []
        )
        record.content = "streamed"
        XCTAssertEqual(record.role, .assistant)
        XCTAssertEqual(record.cliUsed, "claude")
        XCTAssertEqual(record.timestamp, timestamp)
    }

    // remediation(chat-streaming-o2): the streaming append helper now
    // mutates the trailing piece through the array subscript (amortized
    // O(1)) instead of copy-out/copy-back (which forced a full
    // copy-on-write of the accumulated string per chunk — O(n²) per
    // stream). These tests pin the behavioral contract across that change.

    @MainActor
    func testAppendStreamingTranscriptChunk_coalescesSameKindIntoLastPiece() {
        var pieces: [ChatTranscriptPiece] = []
        ChatSessionController.appendStreamingText("Hel", to: &pieces)
        ChatSessionController.appendStreamingText("lo", to: &pieces)
        ChatSessionController.appendStreamingText(" world", to: &pieces)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].kind, .text)
        XCTAssertEqual(pieces[0].value, "Hello world")
    }

    @MainActor
    func testAppendStreamingTranscriptChunk_startsNewPieceOnKindSwitch() {
        var pieces: [ChatTranscriptPiece] = []
        ChatSessionController.appendStreamingTranscriptChunk("think", kind: .reasoning, to: &pieces)
        ChatSessionController.appendStreamingText("answer", to: &pieces)
        ChatSessionController.appendStreamingTranscriptChunk(" more", kind: .text, to: &pieces)
        ChatSessionController.appendStreamingTranscriptChunk("nope", kind: .refusal, to: &pieces)
        XCTAssertEqual(pieces.map(\.kind), [.reasoning, .text, .refusal])
        XCTAssertEqual(pieces.map(\.value), ["think", "answer more", "nope"])
    }

    @MainActor
    func testAppendStreamingTranscriptChunk_ignoresEmptyChunks_andConcatenatesLosslesslyAtScale() {
        var pieces: [ChatTranscriptPiece] = [
            ChatTranscriptPiece(kind: .toolUse, value: "read_file", detail: nil)
        ]
        ChatSessionController.appendStreamingText("", to: &pieces)
        XCTAssertEqual(pieces.count, 1)

        // Thousands of chunks after a tool piece: exactly one trailing text
        // piece, lossless concatenation, and joinedText still matches the
        // incremental accumulator contract used by the streaming loop.
        var expected = ""
        for index in 0..<5_000 {
            let chunk = "t\(index) "
            expected += chunk
            ChatSessionController.appendStreamingText(chunk, to: &pieces)
        }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[1].value, expected)
        XCTAssertEqual(ChatMessageRecord.joinedText(from: pieces), expected)
    }

    func testChatMessageTextLimiter_fastPathMatchesSlowPathForMultibyteText() {
        // The O(1) UTF-8 gate must never change limiter results: multi-byte
        // text whose UTF-8 length exceeds the limit while its character
        // count does not must still return the full text untrimmed.
        let text = String(repeating: "é", count: 3_000) // 3k chars, 6k UTF-8 bytes
        let presentation = ChatMessageTextLimiter.presentation(for: text, expanded: false)
        XCTAssertEqual(presentation.visibleText, text)
        XCTAssertEqual(presentation.hiddenCharacterCount, 0)

        let over = String(repeating: "é", count: ChatMessageTextLimiter.defaultVisibleCharacterLimit + 12)
        let trimmed = ChatMessageTextLimiter.presentation(for: over, expanded: false)
        XCTAssertEqual(trimmed.visibleText.count, ChatMessageTextLimiter.defaultVisibleCharacterLimit)
        XCTAssertEqual(trimmed.hiddenCharacterCount, 12)
    }

    @MainActor
    func testConsumeChatStream_batchesText_andKeepsNewestUsageSnapshot() async throws {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.yield(.text("Hello"))
            continuation.yield(.text(" world"))
            continuation.yield(.reasoning("private"))
            continuation.yield(.refusal("no"))
            continuation.yield(.toolUse(name: "Read", detail: "file.swift"))
            continuation.yield(.toolResult(name: "Read", detail: "ok"))
            continuation.yield(.usage(CLIUsageSnapshot(
                inputTokens: 1,
                outputTokens: 2,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0
            )))
            continuation.yield(.usage(CLIUsageSnapshot(
                inputTokens: 10,
                outputTokens: 20,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0
            )))
            continuation.finish()
        }
        var commits: [(String, [ChatTranscriptPiece])] = []
        var structuralEvents: [CLIChatStreamEvent] = []

        let result = try await ChatSessionController.consumeChatStream(
            stream,
            commitInterval: .hours(1),
            onCommit: { joined, pieces in commits.append((joined, pieces)) },
            onStructuralEvent: { structuralEvents.append($0) }
        )

        XCTAssertEqual(result.joinedText, "Hello world")
        XCTAssertEqual(result.pieces.map(\.kind), [.text, .reasoning, .refusal, .toolUse, .toolResult])
        XCTAssertEqual(result.pieces[0].value, "Hello world")
        XCTAssertEqual(result.pieces[1].value, "private")
        XCTAssertEqual(result.usageSnapshot?.totalTokens, 30)
        XCTAssertEqual(structuralEvents.count, 2)
        XCTAssertEqual(commits.last?.0, "Hello world")
        XCTAssertLessThanOrEqual(commits.count, 4, "usage events must not trigger transcript commits")
    }

    @MainActor
    func testConsumeChatStream_flushesPartialText_beforeRethrowing() async {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            continuation.yield(.text("partial"))
            continuation.yield(.reasoning("thinking"))
            continuation.finish(throwing: StreamTestError.interrupted)
        }
        var commits: [(String, [ChatTranscriptPiece])] = []

        do {
            _ = try await ChatSessionController.consumeChatStream(
                stream,
                commitInterval: .hours(1),
                onCommit: { joined, pieces in commits.append((joined, pieces)) }
            )
            XCTFail("expected the stream error")
        } catch StreamTestError.interrupted {
            XCTAssertEqual(commits.last?.0, "partial")
            XCTAssertEqual(commits.last?.1.map(\.value), ["partial", "thinking"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testConsumeChatStream_throttlesLongTextRun_toBoundedCommits() async throws {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            for index in 0..<200 {
                continuation.yield(.text("chunk-\(index);"))
            }
            continuation.finish()
        }
        var commitCount = 0
        let result = try await ChatSessionController.consumeChatStream(
            stream,
            commitInterval: .hours(1),
            onCommit: { _, _ in commitCount += 1 }
        )

        XCTAssertEqual(result.pieces.count, 1)
        XCTAssertTrue(result.joinedText.hasPrefix("chunk-0;"))
        XCTAssertEqual(commitCount, 2, "first visible delta plus one terminal flush")
    }
}
