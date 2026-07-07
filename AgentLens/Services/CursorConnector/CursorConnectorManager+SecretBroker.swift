import AppKit
import CryptoKit
import Foundation
import Network
import os
import SQLite3
import OpenBurnBarCore

// Cursor connector secret broker and character-set helper.
// Extracted from CursorConnectorManager.swift (god-file decomposition) — same module, verbatim.

#if canImport(OpenBurnBarCore)
import OpenBurnBarCore
#endif
final class CursorConnectorSecretBroker: Sendable {
    // `NWListener` is a Network-framework reference type bound to a queue and is
    // not `Sendable`, so the listener and its derived port live behind an unfair
    // lock with `withLockUnchecked`. Every other stored property is an immutable
    // `let`, giving the type genuine `Sendable` conformance without `@unchecked`.
    private struct BrokerState {
        var listener: NWListener?
        var port: UInt16 = 0
    }

    private let keychain: KeychainStore
    private let routeAccounts: [String: String]
    private let queue = DispatchQueue(label: "openburnbar.cursor.secret-broker")
    private let brokerState = OSAllocatedUnfairLock<BrokerState>(uncheckedState: BrokerState())

    let bearerToken: String

    var port: UInt16 {
        brokerState.withLockUnchecked { $0.port }
    }

    var baseURLString: String {
        "http://127.0.0.1:\(port)"
    }

    init(keychain: KeychainStore, routeAccounts: [String: String]) {
        self.keychain = keychain
        self.routeAccounts = routeAccounts
        self.bearerToken = Self.randomToken()
    }

    func start() async throws {
        var lastError: Error?
        for _ in 0..<20 {
            let candidate = UInt16.random(in: 49152...65535)
            guard let loopback = IPv4Address("127.0.0.1"),
                  let candidatePort = NWEndpoint.Port(rawValue: candidate) else {
                lastError = NSError(
                    domain: "CursorConnectorSecretBroker",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not form loopback endpoint for port \(candidate)."]
                )
                continue
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(loopback),
                    port: candidatePort
                )
                let listener = try NWListener(using: parameters, on: candidatePort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                do {
                    try await waitUntilReady(listener)
                } catch {
                    listener.cancel()
                    lastError = error
                    continue
                }
                brokerState.withLockUnchecked { state in
                    state.listener = listener
                    state.port = candidate
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "CursorConnectorSecretBroker",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not start connector secret broker."]
        )
    }

    /// Bridges `NWListener`'s callback-based state machine into async/await.
    ///
    /// The state handler can fire more than once (`.ready` followed later by
    /// `.failed`/`.cancelled`) and the 2-second readiness deadline races the
    /// callback, so the continuation is guarded by a `Locked` flag that
    /// guarantees it resumes exactly once.
    private func waitUntilReady(_ listener: NWListener, timeout: TimeInterval = 2) async throws {
        let resumed = Locked(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                let shouldResume = resumed.withLock { (alreadyResumed: inout Bool) -> Bool in
                    if alreadyResumed { return false }
                    alreadyResumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(NSError(
                        domain: "CursorConnectorSecretBroker",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
                    )))
                case .cancelled:
                    resumeOnce(.failure(NSError(
                        domain: "CursorConnectorSecretBroker",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Secret broker listener was cancelled before becoming ready."]
                    )))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(NSError(
                    domain: "CursorConnectorSecretBroker",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Secret broker did not become ready."]
                )))
            }
        }
    }

    func stop() {
        brokerState.withLockUnchecked { state in
            state.listener?.cancel()
            state.listener = nil
            state.port = 0
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let response = self.response(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for data: Data?) -> Data {
        guard let data,
              let request = String(data: data, encoding: .utf8) else {
            return http(status: 400, body: ["error": "empty_request"])
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return http(status: 400, body: ["error": "bad_request"])
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return http(status: 400, body: ["error": "bad_request"])
        }

        let authHeader = lines.first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        guard authHeader == "Authorization: Bearer \(bearerToken)" else {
            return http(status: 401, body: ["error": "unauthorized"])
        }

        let path = String(parts[1])
        guard path.hasPrefix("/secret/") else {
            return http(status: 404, body: ["error": "not_found"])
        }

        let routeID = String(path.dropFirst("/secret/".count))
        guard let account = routeAccounts[routeID] else {
            return http(status: 404, body: ["error": "unknown_route"])
        }

        guard let secret = keychain.credentialIfPresent(
                for: account,
                allowUserInteraction: false,
                event: "cursor_secret_broker_key_read_failed"
              ),
              let normalized = quotaNonEmpty(secret) else {
            return http(status: 424, body: ["error": "secret_unavailable"])
        }

        return http(status: 200, body: ["api_key": normalized])
    }

    private func http(status: Int, body: [String: String]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8) // try?-ok(fallback empty body)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 424: reason = "Failed Dependency"
        default: reason = "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(payload.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + payload
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension CharacterSet {
    static let tryCloudflareURLDelimiters = CharacterSet(charactersIn: "<>()[]{}\"'`,;")
        .union(.whitespacesAndNewlines)
}
