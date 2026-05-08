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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (components.host ?? "").lowercased()
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            }
        )
        return decode(host: host, params: params)
    }

    /// Decode a `String` URL form to a `HermesAtom`. Used by the Markdown
    /// link parser to avoid double-allocating `URL` objects.
    public static func decode(_ urlString: String) -> HermesAtom? {
        guard let url = URL(string: urlString) else { return nil }
        return decode(url)
    }

    private static func decode(host: String, params: [String: String]) -> HermesAtom? {
        switch host {
        case "burn":
            let window = params["window"].flatMap(HermesAtomWindow.init(rawValue:)) ?? .today
            let amount = params["amount"].flatMap(Double.init) ?? 0
            return .cost(amount: amount, window: window)
        case "session":
            guard let id = params["id"], !id.isEmpty else { return nil }
            return .session(id: id)
        case "provider":
            guard let token = params["token"], !token.isEmpty else { return nil }
            return .provider(token: token)
        case "model":
            guard let id = params["id"], !id.isEmpty else { return nil }
            return .model(id: id)
        case "window":
            guard let value = params["value"].flatMap(HermesAtomWindow.init(rawValue:)) else { return nil }
            return .window(value)
        case "tool":
            guard let name = params["name"], !name.isEmpty else { return nil }
            return .tool(name: name)
        case "project":
            guard let id = params["id"], !id.isEmpty else { return nil }
            return .project(id: id)
        case "tokens":
            guard let raw = params["value"], let value = Int(raw) else { return nil }
            let scope = params["scope"].flatMap(HermesAtomTokenScope.init(rawValue:)) ?? .unspecified
            return .tokens(value: value, scope: scope)
        case "quota":
            guard let provider = params["provider"], !provider.isEmpty,
                  let percentRaw = params["percent"], let percent = Int(percentRaw) else { return nil }
            return .quota(provider: provider, percent: percent)
        case "runtime":
            guard let profile = params["profile"], !profile.isEmpty else { return nil }
            return .runtime(profile: profile)
        default:
            return nil
        }
    }
}
