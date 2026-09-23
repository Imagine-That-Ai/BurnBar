import Foundation

// Pure code-search formatting helpers, split out of
// BurnBarProjectCodeMemoryStore.swift, which the Swift file-size
// budget holds shrink-only. Internal (not private) so the store's
// call sites in this module keep resolving.

extension BurnBarProjectCodeMemoryStore {
    static func codeEmbeddingVectorStorageByteCount(_ vector: [Float]?) -> Int {
        guard let vector else { return 0 }
        return BurnBarCodeVectorCodec.base64EncodedByteCount(vectorDimension: vector.count)
    }

    /// A short snippet windowed around the first query-token match, else the text head.
    static func codeSnippet(text: String, query: String) -> String {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for token in tokens where token.isEmpty == false {
            if let range = text.range(of: token, options: .caseInsensitive) {
                let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
                let prefix = start > text.startIndex ? "..." : ""
                let suffix = end < text.endIndex ? "..." : ""
                return prefix + String(text[start..<end]) + suffix
            }
        }
        return String(text.prefix(240))
    }

}
