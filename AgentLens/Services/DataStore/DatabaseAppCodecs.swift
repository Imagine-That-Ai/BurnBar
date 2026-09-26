import Foundation
import OpenBurnBarAssistantModels
import OpenBurnBarKernel
import OpenBurnBarData

// MARK: - App-Typed Database Codecs (Wave 2.2 Single Migrator)

// `OpenBurnBarDatabase` itself lives in OpenBurnBarData (the single
// migrator). These four overloads stay in the app because they are typed
// over app-side models: AgentLens's `ChatTranscriptPiece` and
// AssistantModels' `HermesAttachment`. Data ships a wire-identical twin
// over its own Linux-safe model (AssistantModels imports AppIntents, so Data
// cannot depend on it) — same JSON, different Swift types, no conflict.
// The `OpenBurnBarAssistantModels.` qualification below is load-bearing: both
// modules export `HermesAttachment`, so the bare name is ambiguous here.
extension OpenBurnBarDatabase {
    static func encodeTranscriptPieces(_ value: [ChatTranscriptPiece]) throws -> String {
        try encodeJSON(value)
    }

    static func decodeTranscriptPieces(_ string: String?) -> [ChatTranscriptPiece]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([ChatTranscriptPiece].self, from: data) else { // try?-ok(decode fallback nil)
            return nil
        }
        return arr
    }

    static func encodeChatAttachments(_ value: [OpenBurnBarAssistantModels.HermesAttachment]) throws -> String {
        try encodeJSON(value)
    }

    static func decodeChatAttachments(_ string: String?) -> [OpenBurnBarAssistantModels.HermesAttachment]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([OpenBurnBarAssistantModels.HermesAttachment].self, from: data) // try?-ok(decode fallback nil)
    }
}
