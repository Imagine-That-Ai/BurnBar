import Foundation

struct ProjectionChunker {
    let maxChunkCharacters: Int
    let minChunkCharacters: Int
    let overlapCharacters: Int
    let maxChunksPerDocument: Int

    init(
        maxChunkCharacters: Int = 1_200,
        minChunkCharacters: Int = 600,
        overlapCharacters: Int = 140,
        maxChunksPerDocument: Int = 400
    ) {
        self.maxChunkCharacters = max(200, maxChunkCharacters)
        self.minChunkCharacters = max(50, min(minChunkCharacters, maxChunkCharacters))
        self.overlapCharacters = max(0, min(overlapCharacters, maxChunkCharacters / 2))
        self.maxChunksPerDocument = max(1, maxChunksPerDocument)
    }

    func makeChunks(
        text: String,
        sourceKind: SearchSourceKind,
        sourceID: String,
        sourceVersionID: String,
        documentID: String,
        createdAt: Date
    ) -> [SearchChunkRecord] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let nsText = normalizedText as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        let headingAnchors = markdownHeadingAnchors(in: normalizedText)
        let splitSet = CharacterSet.whitespacesAndNewlines

        var chunks: [SearchChunkRecord] = []
        var ordinal = 0
        var start = 0

        while start < length, ordinal < maxChunksPerDocument {
            var end = min(length, start + maxChunkCharacters)
            if end < length {
                let boundaryStart = min(end, start + minChunkCharacters)
                if boundaryStart < end {
                    let boundaryRange = NSRange(location: boundaryStart, length: end - boundaryStart)
                    let boundary = nsText.rangeOfCharacter(
                        from: splitSet,
                        options: [.backwards],
                        range: boundaryRange
                    )
                    if boundary.location != NSNotFound, boundary.location > start {
                        end = boundary.location
                    }
                }
            }

            if end <= start {
                end = min(length, start + maxChunkCharacters)
                if end <= start { break }
            }

            let raw = nsText.substring(with: NSRange(location: start, length: end - start))
            if raw.trimmingCharacters(in: splitSet).isEmpty {
                start = end
                continue
            }

            let sectionPath = sectionPath(for: start, anchors: headingAnchors)
            let chunkID = ProjectionIdentity.chunkID(
                documentID: documentID,
                sourceVersionID: sourceVersionID,
                ordinal: ordinal,
                startOffset: start,
                endOffset: end,
                sectionPath: sectionPath
            )

            let chunkContentHash = ProjectionIdentity.chunkContentHash(
                text: raw,
                sectionPath: sectionPath,
                sourceKind: sourceKind
            )

            chunks.append(
                SearchChunkRecord(
                    id: chunkID,
                    documentID: documentID,
                    sourceKind: sourceKind,
                    sourceID: sourceID,
                    sourceVersionID: sourceVersionID,
                    ordinal: ordinal,
                    startOffset: start,
                    endOffset: end,
                    messageStartOffset: sourceKind == .conversation ? start : nil,
                    messageEndOffset: sourceKind == .conversation ? end : nil,
                    sectionPath: sectionPath,
                    text: raw,
                    contentHash: chunkContentHash,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
            )

            ordinal += 1
            if end >= length { break }
            let nextStart = max(end - overlapCharacters, start + 1)
            start = min(nextStart, length)
        }

        return chunks
    }

    private func markdownHeadingAnchors(in text: String) -> [(offset: Int, path: String)] {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^(#{1,6})\s+(.+?)\s*$"#) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard matches.isEmpty == false else { return [] }

        var stack: [String] = []
        var anchors: [(offset: Int, path: String)] = []

        for match in matches {
            let hashesRange = match.range(at: 1)
            let titleRange = match.range(at: 2)
            guard hashesRange.location != NSNotFound, titleRange.location != NSNotFound else { continue }
            let level = hashesRange.length
            let title = nsText.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.isEmpty == false else { continue }

            while stack.count >= level {
                stack.removeLast()
            }
            stack.append(title)
            anchors.append((offset: match.range.location, path: stack.joined(separator: " / ")))
        }

        return anchors
    }

    private func sectionPath(for offset: Int, anchors: [(offset: Int, path: String)]) -> String? {
        guard anchors.isEmpty == false else { return nil }
        var current: String?
        for anchor in anchors {
            if anchor.offset > offset { break }
            current = anchor.path
        }
        return current
    }
}
