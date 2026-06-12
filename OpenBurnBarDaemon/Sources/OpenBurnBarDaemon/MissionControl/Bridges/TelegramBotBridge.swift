import Foundation

actor BurnBarTelegramBotBridge {
    static let shared = BurnBarTelegramBotBridge()

    private struct TelegramEnvelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
        let description: String?
    }

    private struct TelegramUpdate: Decodable {
        let update_id: Int
        let message: TelegramMessage?
    }

    private struct TelegramMessage: Decodable {
        let text: String?
        let chat: TelegramChat
    }

    private struct TelegramChat: Decodable {
        let id: Int64
    }

    func send(botToken: String, chatID: String, text: String) async throws {
        let url = try endpoint(path: "sendMessage", botToken: botToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "chat_id": chatID,
                "text": text,
                "disable_web_page_preview": true
            ]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(TelegramEnvelope<Bool>.self, from: data)
        guard envelope.ok else {
            throw NSError(
                domain: "BurnBarTelegramBotBridge",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.description ?? "Telegram sendMessage failed."]
            )
        }
    }

    func fetchUpdates(botToken: String, offset: Int?) async throws -> [BurnBarTelegramInboundMessage] {
        var components = URLComponents(url: try endpoint(path: "getUpdates", botToken: botToken), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "timeout", value: "1")]
        if let offset {
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw NSError(domain: "BurnBarTelegramBotBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Telegram updates URL is invalid."])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(TelegramEnvelope<[TelegramUpdate]>.self, from: data)
        guard envelope.ok else {
            throw NSError(
                domain: "BurnBarTelegramBotBridge",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: envelope.description ?? "Telegram getUpdates failed."]
            )
        }
        return envelope.result?.compactMap { update in
            guard let text = update.message?.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
                return nil
            }
            return BurnBarTelegramInboundMessage(
                updateID: update.update_id,
                chatID: String(update.message?.chat.id ?? 0),
                text: text
            )
        } ?? []
    }

    private func endpoint(path: String, botToken: String) throws -> URL {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/\(path)") else {
            throw NSError(domain: "BurnBarTelegramBotBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Telegram endpoint is invalid."])
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown response body"
            throw NSError(
                domain: "BurnBarTelegramBotBridge",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Telegram request failed: \(body)"]
            )
        }
    }
}
