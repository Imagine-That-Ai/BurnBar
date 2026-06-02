import Foundation

// MARK: - Hermes Atom URL Codec
//
// Canonical `burnbar://` URL encoding for `HermesAtom`. The same vocabulary
// is documented to Hermes via `HermesSystemPromptBuilder` so the model emits
// matching markdown links the client can decode.
//
// URL forms:
//   burnbar://burn?window=today&amount=2.34
//   burnbar://session?id=abc-123
//   burnbar://provider?token=anthropic
//   burnbar://model?id=claude-sonnet-4.7
//   burnbar://window?value=7d
//   burnbar://tool?name=ReadFile
//   burnbar://project?id=BurnBar
//   burnbar://tokens?value=12400&scope=today
//   burnbar://quota?provider=anthropic&percent=78
//   burnbar://runtime?profile=hermes

/// Canonical scheme used for in-app navigation links emitted by Hermes.
public let HermesAtomURLScheme = "burnbar"

public enum HermesAtomURL {
    private static let maxURLLength = 2_048
    private static let maxShortPayloadLength = 256
    private static let maxProjectPayloadLength = 512
    private static let maxTokenValue = 1_000_000_000
    private static let maxCostAmount = 1_000_000_000.0

    private static let providerCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let identifierCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:+/-")

    /// Encode a `HermesAtom` to its canonical `burnbar://` URL.
    public static func encode(_ atom: HermesAtom) -> URL {
        var components = URLComponents()
        components.scheme = HermesAtomURLScheme
        switch atom {
        case .cost(let amount, let window):
            components.host = "burn"
            components.queryItems = [
                URLQueryItem(name: "window", value: window.rawValue),
                URLQueryItem(name: "amount", value: String(amount))
            ]
        case .session(let id):
            components.host = "session"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .provider(let token):
            components.host = "provider"
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        case .model(let id):
            components.host = "model"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .window(let value):
            components.host = "window"
            components.queryItems = [URLQueryItem(name: "value", value: value.rawValue)]
        case .tool(let name):
            components.host = "tool"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
        case .project(let id):
            components.host = "project"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .tokens(let value, let scope):
            components.host = "tokens"
            components.queryItems = [
                URLQueryItem(name: "value", value: String(value)),
                URLQueryItem(name: "scope", value: scope.rawValue)
            ]
        case .quota(let provider, let percent):
            components.host = "quota"
            components.queryItems = [
                URLQueryItem(name: "provider", value: provider),
                URLQueryItem(name: "percent", value: String(percent))
            ]
        case .runtime(let profile):
            components.host = "runtime"
            components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        }
        // URLComponents builds the right form even when host has no path.
        return components.url ?? URL(string: "\(HermesAtomURLScheme)://unknown")!
    }

    /// Decode a `URL` back to a `HermesAtom`. Returns `nil` for any URL
    /// that's not a recognized burnbar:// atom — callers should fall back
    /// to rendering the link as plain text.
    public static func decode(_ url: URL) -> HermesAtom? {
        guard url.scheme?.lowercased() == HermesAtomURLScheme else { return nil }
        guard url.absoluteString.count <= maxURLLength else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        guard components.path.isEmpty || components.path == "/" else { return nil }
        let host = (components.host ?? "").lowercased()
        guard let params = decodeQueryItems(components.queryItems ?? []) else { return nil }
        return decode(host: host, params: params)
    }

    /// Decode a `String` URL form to a `HermesAtom`. Used by the Markdown
    /// link parser to avoid double-allocating `URL` objects.
    public static func decode(_ urlString: String) -> HermesAtom? {
        guard urlString.count <= maxURLLength else { return nil }
        guard let url = URL(string: urlString) else { return nil }
        return decode(url)
    }

    private static func decodeQueryItems(_ items: [URLQueryItem]) -> [String: String]? {
        var params: [String: String] = [:]
        for item in items {
            let name = item.name.lowercased()
            guard !name.isEmpty, name.count <= maxShortPayloadLength else { return nil }
            guard params[name] == nil else { return nil }
            guard let value = item.value, value.count <= maxProjectPayloadLength else { return nil }
            guard !containsControlCharacters(name), !containsControlCharacters(value) else { return nil }
            params[name] = value
        }
        return params
    }

    private static func decode(host: String, params: [String: String]) -> HermesAtom? {
        switch host {
        case "burn":
            let window = params["window"].flatMap(HermesAtomWindow.init(rawValue:)) ?? .today
            let amount = params["amount"].flatMap(Double.init) ?? 0
            guard amount.isFinite, amount >= 0, amount <= maxCostAmount else { return nil }
            return .cost(amount: amount, window: window)
        case "session":
            guard let id = params["id"], isOpaquePayload(id, maxLength: maxShortPayloadLength) else { return nil }
            return .session(id: id)
        case "provider":
            guard let token = params["token"], isProviderToken(token) else { return nil }
            return .provider(token: token)
        case "model":
            guard let id = params["id"], isIdentifierToken(id) else { return nil }
            return .model(id: id)
        case "window":
            guard let value = params["value"].flatMap(HermesAtomWindow.init(rawValue:)) else { return nil }
            return .window(value)
        case "tool":
            guard let name = params["name"], isIdentifierToken(name) else { return nil }
            return .tool(name: name)
        case "project":
            guard let id = params["id"], isOpaquePayload(id, maxLength: maxProjectPayloadLength) else { return nil }
            return .project(id: id)
        case "tokens":
            guard let raw = params["value"], let value = Int(raw) else { return nil }
            guard (0...maxTokenValue).contains(value) else { return nil }
            let scope = params["scope"].flatMap(HermesAtomTokenScope.init(rawValue:)) ?? .unspecified
            return .tokens(value: value, scope: scope)
        case "quota":
            guard let provider = params["provider"], !provider.isEmpty,
                  let percentRaw = params["percent"], let percent = Int(percentRaw) else { return nil }
            guard isProviderToken(provider), (0...100).contains(percent) else { return nil }
            return .quota(provider: provider, percent: percent)
        case "runtime":
            guard let profile = params["profile"], isIdentifierToken(profile) else { return nil }
            return .runtime(profile: profile)
        default:
            return nil
        }
    }

    private static func isProviderToken(_ value: String) -> Bool {
        isASCIISet(value, maxLength: maxShortPayloadLength, allowed: providerCharacterSet) && !value.contains("..")
    }

    private static func isIdentifierToken(_ value: String) -> Bool {
        isASCIISet(value, maxLength: maxShortPayloadLength, allowed: identifierCharacterSet) && !value.contains("..")
    }

    private static func isASCIISet(_ value: String, maxLength: Int, allowed: CharacterSet) -> Bool {
        guard !value.isEmpty, value.count <= maxLength, !containsControlCharacters(value) else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isOpaquePayload(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength, !containsControlCharacters(value) else { return false }
        guard !value.contains("://"), !value.contains("\u{0000}") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0 == ".." }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
