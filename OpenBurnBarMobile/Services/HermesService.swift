import Foundation
import OpenBurnBarCore

// MARK: - Hermes Chat Message

struct HermesChatMessage: Identifiable, Equatable {
    let id: String
    let role: HermesChatRole
    var text: String
    let timestamp: Date
    var isStreaming: Bool
    var isError: Bool

    init(
        id: String = UUID().uuidString,
        role: HermesChatRole,
        text: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isError = isError
    }
}

enum HermesChatRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
}

// MARK: - Hermes Service

@Observable
@MainActor
final class HermesService {
    var messages: [HermesChatMessage] = []
    var isStreaming = false
    var lastError: String?
    var isReachable = false

    private var currentTask: Task<Void, Never>?
    private let baseURL: URL
    private let urlSession: URLSession

    init(baseURL: URL = URL(string: "http://localhost:8642")!, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func loadHistory() {}

    func clearChat() {
        currentTask?.cancel()
        currentTask = nil
        messages.removeAll()
        lastError = nil
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = HermesChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)
        isStreaming = true
        lastError = nil

        currentTask?.cancel()
        currentTask = Task { @MainActor in
            do {
                try await streamCompletion()
            } catch {
                if !Task.isCancelled {
                    handleStreamError(error)
                }
            }
        }
    }

    private func streamCompletion() async throws {
        let url = baseURL.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "model": "hermes",
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (stream, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HermesServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw HermesServiceError.httpStatus(code: httpResponse.statusCode)
        }

        isReachable = true

        var assistantMessage = HermesChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistantMessage)

        var buffer = ""
        for try await byte in stream {
            guard !Task.isCancelled else { break }
            buffer.append(Character(UnicodeScalar(byte)))

            while let doubleNewlineRange = buffer.range(of: "\n\n") {
                let event = String(buffer[..<doubleNewlineRange.lowerBound])
                buffer.removeSubrange(..<doubleNewlineRange.upperBound)
                processSSEEvent(event, into: &assistantMessage)
            }
        }

        assistantMessage.isStreaming = false
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            messages[index] = assistantMessage
        }
        isStreaming = false
    }

    private func processSSEEvent(_ event: String, into message: inout HermesChatMessage) {
        var dataLine: String?
        for line in event.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("data: ") {
                dataLine = String(line.dropFirst(6))
            } else if line.hasPrefix(":") || line.isEmpty {
                continue
            }
        }

        guard let data = dataLine else { return }
        if data == "[DONE]" { return }

        guard let jsonData = data.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        if let error = json["error"] as? [String: Any],
           let messageText = error["message"] as? String {
            self.lastError = messageText
            return
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else { return }

        if let content = delta["content"] as? String {
            message.text += content
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
        }
    }

    private func handleStreamError(_ error: Error) {
        isStreaming = false
        isReachable = false

        let displayText: String
        if let hermesError = error as? HermesServiceError {
            displayText = hermesError.localizedDescription
        } else if let urlError = error as? URLError {
            if urlError.code == .cannotConnectToHost || urlError.code == .notConnectedToInternet {
                displayText = "Hermes is not reachable. Make sure it's running on your Mac at localhost:8642 and that both devices are on the same network."
            } else {
                displayText = "Connection error: \(urlError.localizedDescription)"
            }
        } else {
            displayText = "Connection error: \(error.localizedDescription)"
        }

        let errorMessage = HermesChatMessage(
            role: .assistant,
            text: displayText,
            isError: true
        )
        messages.append(errorMessage)
        lastError = displayText
    }

    func checkReachability() async {
        do {
            let (_, response) = try await urlSession.data(from: baseURL)
            isReachable = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            isReachable = false
        }
    }
}

enum HermesServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(code: Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Hermes server."
        case .httpStatus(let code):
            return "Hermes returned HTTP \(code)."
        case .decodingFailed:
            return "Failed to decode the response stream."
        }
    }
}
