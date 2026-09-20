import Foundation

/// Equality follows the source revision, not view state (selection, hover, copy).
struct SessionTranscriptInput: Equatable, Sendable {
    let record: ConversationRecord
    let overrideBody: String?
}

struct SessionTranscriptPreparation: Sendable {
    let sourceText: String
    let blocks: [TranscriptBlock]
    let markdown: String

    static func prepare(_ input: SessionTranscriptInput, reusing previous: Self? = nil) async throws -> Self {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let blocks: [TranscriptBlock]
            if let previous, previous.sourceText == input.record.fullText {
                blocks = previous.blocks
            } else {
                blocks = TranscriptBlockParser.parse(input.record.fullText) { Task.isCancelled }
            }
            try Task.checkCancellation()
            let markdown: String
            if let override = input.overrideBody, !override.isEmpty {
                markdown = override
            } else {
                markdown = SessionLogMarkdownFormatter.markdown(for: input.record)
            }
            try Task.checkCancellation()
            return Self(sourceText: input.record.fullText, blocks: blocks, markdown: markdown)
        }
        let prepared = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return prepared
    }
}
