import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import os
import XCTest

extension GatewayHarness {
    func safariHeaders(correlationID: String) async -> [String: String] {
        guard let capability = await safariAttributionAuthority.issue(
            clientID: safariClientID,
            sessionID: safariSessionID
        ) else {
            XCTFail("Expected the attached Safari test session to receive an attribution capability.")
            return [:]
        }
        return [
            "Content-Type": "application/json",
            "X-OpenBurnBar-Client": GatewayRequestAttribution.safariClientSource,
            "X-OpenBurnBar-Correlation-ID": correlationID,
            "X-OpenBurnBar-Attribution-Capability": capability.token
        ]
    }

    static func makeUpstreamSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayUpstreamURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func configureZAIProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "backup",
            label: "Backup",
            apiKey: "backup-key"
        )
    }

    func configureAnthropicProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-sonnet-4-6-family"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "primary",
            label: "Primary",
            apiKey: "sk-ant-api03-primary-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "backup",
            label: "Backup",
            apiKey: "sk-ant-api03-backup-key"
        )
    }

    func configureOllamaProviderForGateway(
        preferredModelIDs: [String] = ["deepseek-v4-flash"]
    ) async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/api",
                preferredModelIDs: preferredModelIDs,
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-ollama-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "backup",
            label: "Backup",
            apiKey: "backup-ollama-key"
        )
    }

    func configureFactoryProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "factory",
            slotID: "max",
            label: "Factory Max",
            apiKey: "fk-gateway"
        )
    }

    static func reservePort() throws -> Int {
        var lastError: POSIXError?
        for _ in 0..<4096 {
            let candidate = nextPortCandidate()
            do {
                try verifyCanBind(port: candidate)
                return candidate
            } catch let error as POSIXError {
                lastError = error
            }
        }
        throw lastError ?? POSIXError(.EADDRINUSE)
    }

    static func nextPortCandidate() -> Int {
        nextCandidatePort.withLock { nextPort in
            let candidate = nextPort
            nextPort += 1
            if nextPort > 60_999 {
                nextPort = 49_152
            }
            return candidate
        }
    }
}

/// Test-only logger that captures all log emissions for assertion. Conforms to
/// `BurnBarDaemonLogging` so it can be injected anywhere the gateway accepts a
/// logger. Uses `OSAllocatedUnfairLock` for lock-free thread safety with native
/// `Sendable` conformance — no `@unchecked Sendable` needed.
struct CapturingDaemonLogger: BurnBarDaemonLogging {
    struct Entry: Sendable {
        let level: String
        let event: String
        let metadata: [String: String]
    }

    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    var captured: [Entry] {
        entries.withLock { $0 }
    }

    func debug(_ event: String, metadata: [String: String] = [:]) {
        entries.withLock { $0.append(Entry(level: "debug", event: event, metadata: metadata)) }
    }

    func info(_ event: String, metadata: [String: String] = [:]) {
        entries.withLock { $0.append(Entry(level: "info", event: event, metadata: metadata)) }
    }

    func notice(_ event: String, metadata: [String: String] = [:]) {
        entries.withLock { $0.append(Entry(level: "notice", event: event, metadata: metadata)) }
    }

    func warning(_ event: String, metadata: [String: String] = [:]) {
        entries.withLock { $0.append(Entry(level: "warning", event: event, metadata: metadata)) }
    }

    func error(_ event: String, metadata: [String: String] = [:]) {
        entries.withLock { $0.append(Entry(level: "error", event: event, metadata: metadata)) }
    }

    func silentFailure(_ operation: String, error: Error, context: [String: String] = [:]) {
        let metadata = context.merging(["error": String(describing: error)]) { _, new in new }
        entries.withLock { $0.append(Entry(level: "warning", event: operation, metadata: metadata)) }
    }
}
