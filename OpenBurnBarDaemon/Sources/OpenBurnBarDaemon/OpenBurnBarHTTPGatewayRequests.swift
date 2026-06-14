import Foundation

struct ChatCompletionsRequest: Decodable {
    let model: String
    let stream: Bool?
}

struct ResponsesRequest: Decodable {
    let model: String
    let stream: Bool?
}

struct AnthropicMessagesRequest: Decodable {
    let model: String
    let stream: Bool?
}
