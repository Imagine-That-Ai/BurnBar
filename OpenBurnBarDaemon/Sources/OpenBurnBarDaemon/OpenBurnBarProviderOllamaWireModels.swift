import OpenBurnBarCore
import Foundation

struct OllamaNativeChatResponse: Decodable {
    struct Message: Decodable {
        let role: String?
        let content: String?
        let thinking: String?
        let toolCalls: [OllamaNativeToolCall]?

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case thinking
            case tool_calls
            case toolCalls
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decodeIfPresent(String.self, forKey: .role)
            content = try container.decodeIfPresent(String.self, forKey: .content)
            thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
            toolCalls = try container.decodeIfPresent([OllamaNativeToolCall].self, forKey: .tool_calls)
                ?? container.decodeIfPresent([OllamaNativeToolCall].self, forKey: .toolCalls)
        }
    }

    let model: String?
    let createdAt: String?
    let message: Message?
    let done: Bool?
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

struct OllamaNativeToolCall: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: BurnBarJSONValue?
    }

    let id: String?
    let type: String?
    let function: Function?
}
