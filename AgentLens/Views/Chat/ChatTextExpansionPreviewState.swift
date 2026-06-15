import Foundation

struct ChatTextExpansionPreviewState: Identifiable, Equatable {
    let id: String
    let snippetID: String
    let title: String
    let token: String
    var generatedText: String
    var isLoading: Bool
    var errorMessage: String?

    init(
        id: String = UUID().uuidString,
        snippetID: String,
        title: String,
        token: String,
        generatedText: String = "",
        isLoading: Bool = true,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.snippetID = snippetID
        self.title = title
        self.token = token
        self.generatedText = generatedText
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

enum TextExpansionRewriteError: LocalizedError {
    case unsupportedBackend(String)
    case invalidGatewayURL
    case missingModel
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedBackend(let backend):
            return "LLM snippet previews require Hermes, OpenClaw, or Pi. Current backend: \(backend)."
        case .invalidGatewayURL:
            return "The selected chat gateway URL is invalid."
        case .missingModel:
            return "Select a model before using LLM snippet previews."
        case .emptyResponse:
            return "The model returned an empty preview."
        }
    }
}
