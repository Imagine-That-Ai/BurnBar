import Foundation
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Pi Agent Pairing Servicing

/// Pi-agent pairing domain slice of the Firebase callable surface, split out
/// of `FunctionsRepository` (tech-debt finding-67). Owns the Pi agent host
/// pairing/connection lifecycle callables. Method bodies are verbatim moves
/// from `FunctionsRepository`; the repository remains a facade that forwards
/// here, so existing call sites keep compiling unchanged.
@MainActor
protocol PiPairingServicing: AnyObject {
    func createPiAgentPairing(
        deviceId: String?,
        platform: String?,
        displayName: String?
    ) async throws -> PiPairingSessionRecord

    func completePiAgentPairing(
        pairingId: String,
        code: String,
        connectionId: String?,
        displayName: String,
        mode: PiConnectionMode,
        endpointURL: String,
        advertisedModel: String?,
        selectedInstanceID: String?,
        redisURL: String?,
        capabilities: [String],
        instances: [PiAgentInstanceRecord],
        models: [PiAgentRuntimeModelOption],
        relayPublicKey: String?,
        relayKeyVersion: Int?,
        relayEncryption: String?,
        realtimeRelayURL: String?,
        realtimeRelayStatus: String?,
        deviceId: String?
    ) async throws -> PiConnectionRecord

    func listPiAgentConnections(includeRevoked: Bool) async throws -> [PiConnectionRecord]
    func revokePiAgentConnection(connectionId: String, deviceId: String?) async throws

    func updatePiAgentConnectionStatus(
        connectionId: String,
        status: PiConnectionStatus,
        advertisedModel: String?,
        selectedInstanceID: String?,
        capabilities: [String]?,
        instances: [PiAgentInstanceRecord]?,
        models: [PiAgentRuntimeModelOption]?,
        deviceId: String?
    ) async throws
}

// MARK: - Pi Agent Pairing API

@MainActor
final class PiPairingAPI: PiPairingServicing {
    private let client: FunctionsClientProvider

    init(client: FunctionsClientProvider) {
        self.client = client
    }

    private func functionsClient() throws -> Functions {
        try client.client()
    }

    func createPiAgentPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> PiPairingSessionRecord {
        let callable = try functionsClient().httpsCallable("createPiAgentPairing")
        var payload: [String: Any] = [:]
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        if let platform, !platform.isEmpty { payload["platform"] = platform }
        if let displayName, !displayName.isEmpty { payload["displayName"] = displayName }

        let result = try await callable.call(payload)
        return try decodeHermesValue(PiPairingSessionRecord.self, from: result.data)
    }

    func completePiAgentPairing(
        pairingId: String,
        code: String,
        connectionId: String? = nil,
        displayName: String,
        mode: PiConnectionMode = .directURL,
        endpointURL: String,
        advertisedModel: String? = nil,
        selectedInstanceID: String? = nil,
        redisURL: String? = nil,
        capabilities: [String] = ["chat_completions"],
        instances: [PiAgentInstanceRecord] = [],
        models: [PiAgentRuntimeModelOption] = [],
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        realtimeRelayURL: String? = nil,
        realtimeRelayStatus: String? = nil,
        deviceId: String? = nil
    ) async throws -> PiConnectionRecord {
        let callable = try functionsClient().httpsCallable("completePiAgentPairing")
        var payload: [String: Any] = [
            "pairingId": pairingId,
            "code": code,
            "displayName": displayName,
            "mode": mode.rawValue,
            "endpointURL": endpointURL,
            "capabilities": capabilities
        ]
        if let connectionId, !connectionId.isEmpty { payload["connectionId"] = connectionId }
        if let advertisedModel, !advertisedModel.isEmpty { payload["advertisedModel"] = advertisedModel }
        if let selectedInstanceID, !selectedInstanceID.isEmpty { payload["selectedInstanceID"] = selectedInstanceID }
        if let redisURL, !redisURL.isEmpty { payload["redisURL"] = redisURL }
        if !instances.isEmpty { payload["instances"] = try encodedFunctionValue(instances) }
        if !models.isEmpty { payload["models"] = try encodedFunctionValue(models) }
        if let relayPublicKey, !relayPublicKey.isEmpty { payload["relayPublicKey"] = relayPublicKey }
        if let relayKeyVersion { payload["relayKeyVersion"] = relayKeyVersion }
        if let relayEncryption, !relayEncryption.isEmpty { payload["relayEncryption"] = relayEncryption }
        if let realtimeRelayURL, !realtimeRelayURL.isEmpty { payload["realtimeRelayURL"] = realtimeRelayURL }
        if let realtimeRelayStatus, !realtimeRelayStatus.isEmpty { payload["realtimeRelayStatus"] = realtimeRelayStatus }
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }

        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try decodeHermesValue(PiConnectionRecord.self, from: result.data)
    }

    func listPiAgentConnections(includeRevoked: Bool = false) async throws -> [PiConnectionRecord] {
        let callable = try functionsClient().httpsCallable("listPiAgentConnections")
        let result = try await callable.call(["includeRevoked": includeRevoked])
        guard
            let dict = result.data as? [String: Any],
            let connections = dict["connections"]
        else {
            throw FunctionsError.decodingFailed
        }
        return try decodeHermesValue([PiConnectionRecord].self, from: connections)
    }

    func revokePiAgentConnection(connectionId: String, deviceId: String? = nil) async throws {
        let callable = try functionsClient().httpsCallable("revokePiAgentConnection")
        var payload: [String: Any] = ["connectionId": connectionId]
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        _ = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
    }

    func updatePiAgentConnectionStatus(
        connectionId: String,
        status: PiConnectionStatus,
        advertisedModel: String? = nil,
        selectedInstanceID: String? = nil,
        capabilities: [String]? = nil,
        instances: [PiAgentInstanceRecord]? = nil,
        models: [PiAgentRuntimeModelOption]? = nil,
        deviceId: String? = nil
    ) async throws {
        let callable = try functionsClient().httpsCallable("updatePiAgentConnectionStatus")
        var payload: [String: Any] = [
            "connectionId": connectionId,
            "status": status.rawValue
        ]
        if let advertisedModel, !advertisedModel.isEmpty { payload["advertisedModel"] = advertisedModel }
        if let selectedInstanceID, !selectedInstanceID.isEmpty { payload["selectedInstanceID"] = selectedInstanceID }
        if let capabilities { payload["capabilities"] = capabilities }
        if let instances { payload["instances"] = try encodedFunctionValue(instances) }
        if let models { payload["models"] = try encodedFunctionValue(models) }
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        _ = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
    }

    private func decodeHermesValue<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(raw)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(type, from: data)
    }

    private func encodedFunctionValue<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
