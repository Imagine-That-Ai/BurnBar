import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarKernel

final class ReceiptChatBridgeTests: XCTestCase {
    func test_genericAccomplishment_matchesThePlaceholderAndSessionCompletedLines() {
        XCTAssertTrue(ReceiptChatBridge.isGenericAccomplishment("Session completed successfully"))
        XCTAssertTrue(ReceiptChatBridge.isGenericAccomplishment("Session completed in OpenBurnBar"))
        XCTAssertTrue(ReceiptChatBridge.isGenericAccomplishment("  "))
        XCTAssertFalse(ReceiptChatBridge.isGenericAccomplishment("Added the Chat lens to receipts"))
    }

    func test_contentSummary_prefersConversationSummaryOverGenericAccomplishment() {
        let receipt = ReceiptRecord(
            sessionId: "codex-1",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol",
            promptSummary: "OpenBurnBar",
            actualAccomplishments: ["Session completed successfully"]
        )
        let overlay = ReceiptConversationOverlay(
            conversationID: "conv-1",
            sessionID: "codex-1",
            inferredTaskTitle: "OpenBurnBar",
            summary: "Wire receipts to the indexed chat so the slip shows what was said.",
            summaryTitle: "Receipt transcripts",
            workingDirectory: "/Users/alberto/BurnBar",
            messageCount: 8,
            keyFiles: ["ReceiptCardView.swift"]
        )

        XCTAssertEqual(
            ReceiptChatBridge.contentSummary(receipt: receipt, overlay: overlay),
            "Wire receipts to the indexed chat so the slip shows what was said."
        )
        XCTAssertEqual(
            ReceiptChatBridge.listPreview(receipt: receipt, overlay: overlay),
            "Wire receipts to the indexed chat so the slip shows what was said."
        )
    }

    func test_listPreview_doesNotLeadWithTheGenericPlaceholder() {
        let receipt = ReceiptRecord(
            sessionId: "codex-1",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol",
            actualAccomplishments: ["Session completed successfully"]
        )
        XCTAssertEqual(
            ReceiptChatBridge.listPreview(receipt: receipt),
            "Untitled chat in OpenBurnBar"
        )
    }

    func test_firstUserPrompt_readsHumanTurnsFromATranscript() {
        let text = """
        ## You
        Add links and a transcript to receipts.

        ## Assistant
        I'll open the session log and join it to the slip.
        """
        XCTAssertEqual(
            ReceiptChatBridge.firstUserPrompt(from: text),
            "Add links and a transcript to receipts."
        )
    }

    func test_sessionAndReceiptURLs_areOpenBurnBarDeepLinks() {
        XCTAssertEqual(
            ReceiptChatBridge.sessionURL(conversationID: "conv-1")?.absoluteString,
            "openburnbar://sessions/conv-1"
        )
        XCTAssertEqual(
            ReceiptChatBridge.receiptURL(receiptID: "rcpt-1")?.absoluteString,
            "openburnbar://receipts/rcpt-1"
        )
        let chatTape = ReceiptChatBridge.receiptURL(receiptID: "rcpt-1", lens: .transcript)
        XCTAssertEqual(chatTape?.scheme, "openburnbar")
        XCTAssertEqual(chatTape?.host, "receipts")
        XCTAssertEqual(chatTape?.path, "/rcpt-1")
        XCTAssertEqual(
            URLComponents(url: chatTape!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "lens" })?.value,
            "chat"
        )
        XCTAssertEqual(ReceiptLens.fromDeepLinkToken("chat"), .transcript)
        XCTAssertEqual(ReceiptLens.transcript.deepLinkToken, "chat")
        XCTAssertNil(ReceiptChatBridge.sessionURL(conversationID: "  "))
        XCTAssertEqual(
            ReceiptChatBridge.sessionURL(conversationID: "conv with space")?.absoluteString,
            "openburnbar://sessions/conv%20with%20space"
        )
        let spaced = URL(string: "OpenBurnBar://RECEIPTS/rcpt%20with%20space?lens=chat")!
        XCTAssertEqual(ReceiptChatBridge.receiptID(from: spaced), "rcpt with space")
        XCTAssertEqual(ReceiptChatBridge.receiptLens(from: spaced), .transcript)
        XCTAssertEqual(
            ReceiptChatBridge.sessionID(from: URL(string: "openburnbar://sessions/conv-1")!),
            "conv-1"
        )
        XCTAssertNil(ReceiptChatBridge.receiptID(from: URL(string: "openburnbar://sessions/conv-1")!))
        XCTAssertNil(ReceiptChatBridge.sessionID(from: URL(string: "openburnbar://receipts/rcpt-1")!))
        XCTAssertNil(ReceiptChatBridge.pathIdentifier(from: URL(string: "openburnbar://receipts/")!))

        let slashed = "parentSession/agentId"
        let slashedURL = ReceiptChatBridge.receiptURL(receiptID: slashed)
        XCTAssertEqual(
            slashedURL?.absoluteString,
            "openburnbar://receipts/parentSession%2FagentId"
        )
        XCTAssertEqual(ReceiptChatBridge.receiptID(from: slashedURL!), slashed)
        XCTAssertEqual(
            ReceiptChatBridge.pathIdentifier(
                from: URL(string: "openburnbar://sessions/parentSession/agentId")!
            ),
            slashed
        )
    }

    func test_transcriptTape_capsTheFullTape() {
        let blocks = (0..<120).map { index in
            TranscriptBlock(kind: .toolUse, content: "tool \(index)", label: nil)
        }
        XCTAssertEqual(
            ReceiptTranscriptTape.fullTapeBlocks(blocks).count,
            ReceiptTranscriptTape.fullTapeBlockCap
        )
        XCTAssertEqual(
            ReceiptTranscriptTape.omittedFullTapeCount(blocks),
            120 - ReceiptTranscriptTape.fullTapeBlockCap
        )
    }

    func test_overlayLookup_findsAReceiptMintedAgainstEitherConversationKey() {
        let overlay = ReceiptConversationOverlay(
            conversationID: "conv-1",
            sessionID: "sess-1",
            inferredTaskTitle: "Title",
            summary: "Summary",
            summaryTitle: nil,
            workingDirectory: nil,
            messageCount: 4,
            keyFiles: []
        )
        let map = ["conv-1": overlay, "sess-1": overlay]
        XCTAssertEqual(ReceiptConversationOverlay.lookup("sess-1", in: map)?.conversationID, "conv-1")
        XCTAssertEqual(ReceiptConversationOverlay.lookup("conv-1", in: map)?.sessionID, "sess-1")

        let idOnly = ["conv-1": overlay]
        XCTAssertEqual(
            ReceiptConversationOverlay.lookup("sess-1", in: idOnly)?.conversationID,
            "conv-1",
            "A slip minted on sessionId still finds an overlay keyed only by conversations.id"
        )
    }

    func test_revealURL_joinsRelativeFilesOntoTheWorkingDirectory() {
        let url = ReceiptChatBridge.revealURL(
            workingDirectory: "/tmp/project",
            relativePath: "Sources/App.swift"
        )
        XCTAssertEqual(url?.path, "/tmp/project/Sources/App.swift")
    }

    func test_conversationLookupKeys_prefersOverlayConversationId() {
        let receipt = ReceiptRecord(
            sessionId: "sess-1",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol"
        )
        let overlay = ReceiptConversationOverlay(
            conversationID: "conv-1",
            sessionID: "sess-1",
            inferredTaskTitle: "Title",
            summary: "Summary",
            summaryTitle: nil,
            workingDirectory: nil,
            messageCount: 4,
            keyFiles: []
        )
        XCTAssertEqual(
            ReceiptChatBridge.conversationLookupKeys(receipt: receipt, overlay: overlay),
            ["conv-1", "sess-1"]
        )
        XCTAssertEqual(
            ReceiptChatBridge.conversationID(receipt: receipt, overlay: overlay),
            "conv-1"
        )
        XCTAssertEqual(
            ReceiptChatBridge.conversationLookupKeys(receipt: receipt, overlay: nil),
            ["sess-1"]
        )
    }

    func test_receiptLens_includesChat() {
        XCTAssertTrue(ReceiptLens.allCases.contains(.transcript))
        XCTAssertEqual(ReceiptLens.transcript.pickerTitle, "Chat")
        XCTAssertEqual(ReceiptLens.transcript.title, "Chat")
    }

    func test_contentSummary_readsTheFirstUserTurnWhenNoStoredSummaryExists() {
        let receipt = ReceiptRecord(
            sessionId: "codex-1",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol",
            actualAccomplishments: ["Session completed successfully"]
        )
        let transcript = ConversationRecord(
            id: "conv-1",
            provider: .codex,
            sessionId: "codex-1",
            projectName: "OpenBurnBar",
            startTime: Date(),
            endTime: Date(),
            messageCount: 2,
            userWordCount: 8,
            assistantWordCount: 12,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "OpenBurnBar",
            lastAssistantMessage: "",
            fullText: """
            ## You
            Add links and a transcript to receipts.

            ## Assistant
            Opening Session Logs from the slip.
            """,
            fileModifiedAt: Date()
        )
        XCTAssertEqual(
            ReceiptChatBridge.contentSummary(receipt: receipt, transcript: transcript),
            "Add links and a transcript to receipts."
        )
    }
}
