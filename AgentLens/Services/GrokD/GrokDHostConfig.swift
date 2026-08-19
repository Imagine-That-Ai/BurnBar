import Foundation

/// Loopback-only Local D box endpoints. Never uses `localhost` (`::1`).
struct GrokDHostConfig: Equatable, Sendable {
    static let loopbackHost = "127.0.0.1"
    static let shimPort: UInt16 = 1337
    static let hostPort: UInt16 = 1338
    static let inferencePort: UInt16 = 8787
    /// Bearer the shim forwards to `:1338`. `active-env.json` writes this for
    /// local profiles and omits it on Cursor seats; the pane still talks to the
    /// Local D box, not the GUI seat.
    static let localBoxShimBearer = "fake-gateway-token"

    let loopbackHost: String
    let shimPort: UInt16
    let hostPort: UInt16
    let inferencePort: UInt16
    let bearerToken: String
    let guiMode: String?

    var shimBaseURL: URL {
        URL(string: "http://\(loopbackHost):\(shimPort)")!
    }

    var guiIsLocalProfile: Bool {
        guard let guiMode else { return true }
        return guiMode == "local"
    }

    static func defaultActiveEnvURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".grok/grokbot-d/active-env.json")
    }

    static func defaultEnsureLocalBoxURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".grok/grokbot-d/ensure-local-box.sh")
    }

    static func load(
        fromActiveEnv url: URL = GrokDHostConfig.defaultActiveEnvURL(),
        fileManager: FileManager = .default
    ) throws -> GrokDHostConfig {
        guard fileManager.fileExists(atPath: url.path) else {
            throw GrokDHostError.missingActiveEnv
        }
        let data = try Data(contentsOf: url)
        let env = try JSONDecoder().decode(GrokDActiveEnvFile.self, from: data)
        let rawToken = env.SAND_HOST_GATEWAY_TOKEN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token: String
        if rawToken.isEmpty {
            // Local profiles write the shim bearer. Cursor seats omit it; only
            // then do we fall back. A blank local token is a broken env file.
            if env.mode == "local" {
                throw GrokDHostError.missingToken
            }
            token = localBoxShimBearer
        } else {
            token = rawToken
        }
        return GrokDHostConfig(
            loopbackHost: loopbackHost,
            shimPort: shimPort,
            hostPort: hostPort,
            inferencePort: inferencePort,
            bearerToken: token,
            guiMode: env.mode
        )
    }

    func apiURL(_ method: String) -> URL {
        shimBaseURL.appendingPathComponent("api").appendingPathComponent(method)
    }
}

extension GrokDHostConfig: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "GrokDHostConfig(host: \(loopbackHost), shim: \(shimPort), hostPort: \(hostPort), inference: \(inferencePort), token: <redacted>, guiMode: \(guiMode ?? "nil"))"
    }

    var debugDescription: String { description }
}

private struct GrokDActiveEnvFile: Decodable {
    var mode: String?
    var SAND_HOST_GATEWAY_TOKEN: String?
}
