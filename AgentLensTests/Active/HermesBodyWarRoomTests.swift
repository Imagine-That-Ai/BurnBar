import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBar

/// Pins the HermesBodyPublisher payload contract against the firestore.rules
/// `hermesBodyWrite` key allowlist, and the HermesBodyRecord reader-derived
/// presence + fromFirestore parser. A drift here means the heartbeat write
/// is silently rejected (publisher) or the directory renders garbage (reader).
final class HermesBodyWarRoomTests: XCTestCase {

    // MARK: - Payload vs rules allowlist

    private func makeInput() -> HermesBodyPublisher.PayloadInput {
        HermesBodyPublisher.PayloadInput(
            bodyID: "relay-host-test-uuid",
            deviceID: "device-abc-123",
            machineName: "Alberto's Mac Studio",
            hardware: MacHardwareInventory(
                hardwareModel: "mac14,13",
                chipBrand: "Apple M2 Ultra",
                coresPerformance: 16,
                coresEfficiency: 4,
                memBytes: 64_000_000_000
            ),
            hermes: HermesBodyPublisher.HermesState(
                installed: true,
                gatewayReachable: true,
                version: nil
            ),
            irohNodeID: "node-xyz",
            now: "2026-08-17T20:00:00Z"
        )
    }

    /// Every key in the payload must be in the rules allowlist:
    /// id, deviceID, displayName, machineName, platform, hardware, hermes,
    /// endpoints, presence, capabilities, schemaVersion, createdAt, updatedAt
    func test_payloadKeysMatchRulesAllowlist() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        let allowedKeys: Set<String> = [
            "id", "deviceID", "displayName", "machineName", "platform",
            "hardware", "hermes", "endpoints", "presence", "capabilities",
            "schemaVersion", "createdAt", "updatedAt"
        ]
        let payloadKeys = Set(payload.keys)
        XCTAssertTrue(payloadKeys.isSubset(of: allowedKeys),
                      "payload has keys outside rules allowlist: \(payloadKeys.subtracting(allowedKeys))")
    }

    func test_payloadCreationIncludesDisplayNameAndCreatedAt() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: true)
        XCTAssertEqual(payload["displayName"] as? String, "Alberto's Mac Studio Hermes")
        XCTAssertNotNil(payload["createdAt"])
    }

    func test_payloadHeartbeatOmitsDisplayName() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        XCTAssertNil(payload["displayName"])
        XCTAssertNil(payload["createdAt"])
    }

    func test_payloadRequiredFields() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        XCTAssertEqual(payload["id"] as? String, "relay-host-test-uuid")
        XCTAssertEqual(payload["deviceID"] as? String, "device-abc-123")
        XCTAssertEqual(payload["machineName"] as? String, "Alberto's Mac Studio")
        XCTAssertEqual(payload["platform"] as? String, "macos")
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(payload["updatedAt"])
    }

    func test_payloadHardwareBlock() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        let hardware = payload["hardware"] as? [String: Any]
        XCTAssertEqual(hardware?["hardwareModel"] as? String, "mac14,13")
        XCTAssertEqual(hardware?["chipBrand"] as? String, "Apple M2 Ultra")
        XCTAssertEqual(hardware?["coresPerformance"] as? Int, 16)
        XCTAssertEqual(hardware?["coresEfficiency"] as? Int, 4)
        XCTAssertEqual(hardware?["memBytes"] as? Int64, 64_000_000_000)
    }

    func test_payloadHermesBlock() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        let hermes = payload["hermes"] as? [String: Any]
        XCTAssertEqual(hermes?["installed"] as? Bool, true)
        XCTAssertEqual(hermes?["gatewayReachable"] as? Bool, true)
    }

    func test_payloadPresenceBlock() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        let presence = payload["presence"] as? [String: Any]
        XCTAssertEqual(presence?["state"] as? String, "online")
        XCTAssertEqual(presence?["lastHeartbeatAt"] as? String, "2026-08-17T20:00:00Z")
        XCTAssertEqual(presence?["wireReachable"] as? Bool, true)
    }

    /// A body with no published NodeId is not dialable, and says so: peers plan
    /// `.noEndpoint` for it and keep the Firestore road instead of dialing a
    /// machine that cannot answer.
    func test_payloadWithoutAnEndpointReportsTheWireUnreachable() {
        var input = makeInput()
        input.irohNodeID = nil
        let payload = HermesBodyPublisher.payload(input, includeCreationDefaults: false)
        let presence = payload["presence"] as? [String: Any]
        let endpoints = payload["endpoints"] as? [String: Any]
        XCTAssertEqual(presence?["wireReachable"] as? Bool, false)
        XCTAssertNil(endpoints?["irohNodeId"])
        XCTAssertFalse((payload["capabilities"] as? [String])?.contains(WarWireFrameCodec.capability) ?? true)
    }

    /// The Wire capability is advertised only by a body that can actually be
    /// dialled, because the peer's gate refuses a hello without it.
    func test_payloadAdvertisesTheWireCapabilityWithAnEndpoint() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        XCTAssertTrue((payload["capabilities"] as? [String])?.contains(WarWireFrameCodec.capability) ?? false)
    }

    func test_payloadEndpointsBlock() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        let endpoints = payload["endpoints"] as? [String: Any]
        XCTAssertEqual(endpoints?["pairingConnectionId"] as? String, "relay-host-test-uuid")
        XCTAssertEqual(endpoints?["irohNodeId"] as? String, "node-xyz")
    }

    func test_payloadCapabilitiesIncludeFleetProbe() {
        let payload = HermesBodyPublisher.payload(makeInput(), includeCreationDefaults: false)
        let capabilities = payload["capabilities"] as? [String]
        XCTAssertTrue(capabilities?.contains("fleet_probe") ?? false)
        XCTAssertTrue(capabilities?.contains("hermes_chat") ?? false)
    }

    func test_payloadCapabilitiesNoHermesChatWhenGatewayOff() {
        var input = makeInput()
        input.hermes = .init(installed: true, gatewayReachable: false, version: nil)
        let payload = HermesBodyPublisher.payload(input, includeCreationDefaults: false)
        let capabilities = payload["capabilities"] as? [String]
        XCTAssertTrue(capabilities?.contains("fleet_probe") ?? false)
        XCTAssertFalse(capabilities?.contains("hermes_chat") ?? true)
    }

    func test_payloadOmitsNilHardwareFields() {
        var input = makeInput()
        input.hardware = MacHardwareInventory(
            hardwareModel: nil, chipBrand: nil,
            coresPerformance: nil, coresEfficiency: nil, memBytes: nil
        )
        let payload = HermesBodyPublisher.payload(input, includeCreationDefaults: false)
        let hardware = payload["hardware"] as? [String: Any]
        XCTAssertTrue(hardware?.isEmpty ?? false)
    }

    func test_defaultDisplayName() {
        XCTAssertEqual(HermesBodyPublisher.defaultDisplayName(machineName: "My Mac"), "My Mac Hermes")
        XCTAssertEqual(HermesBodyPublisher.defaultDisplayName(machineName: "  "), "Mac Hermes")
        XCTAssertEqual(HermesBodyPublisher.defaultDisplayName(machineName: ""), "Mac Hermes")
    }

    // MARK: - HermesState.probeLive

    /// A gateway that answers 200 proves both install and reachability without
    /// paying for executable resolution.
    func test_probeLiveGatewayAvailable() async {
        var resolvedExecutable = false
        let state = await HermesBodyPublisher.HermesState.probeLive(
            baseURL: URL(string: "http://127.0.0.1:8642")!,
            bearerToken: nil,
            dependencies: makeDependencies(
                probe: (available: true, authRejected: false, modelName: "hermes"),
                executable: "/usr/local/bin/hermes",
                onResolveExecutable: { resolvedExecutable = true }
            )
        )
        XCTAssertEqual(state, .init(installed: true, gatewayReachable: true, version: nil))
        XCTAssertFalse(resolvedExecutable, "a live gateway must not trigger executable resolution")
    }

    /// A 401/403 still proves a gateway is up — it just rejected our key.
    func test_probeLiveGatewayAuthRejectedCountsAsReachable() async {
        let state = await HermesBodyPublisher.HermesState.probeLive(
            baseURL: URL(string: "http://127.0.0.1:8642")!,
            bearerToken: "wrong-key",
            dependencies: makeDependencies(
                probe: (available: false, authRejected: true, modelName: nil),
                executable: nil
            )
        )
        XCTAssertEqual(state, .init(installed: true, gatewayReachable: true, version: nil))
    }

    func test_probeLiveFallsBackToExecutableForInstallVerdict() async {
        let state = await HermesBodyPublisher.HermesState.probeLive(
            baseURL: URL(string: "http://127.0.0.1:8642")!,
            bearerToken: nil,
            dependencies: makeDependencies(
                probe: (available: false, authRejected: false, modelName: nil),
                executable: "/opt/homebrew/bin/hermes"
            )
        )
        XCTAssertEqual(state, .init(installed: true, gatewayReachable: false, version: nil))
    }

    func test_probeLiveReportsNotInstalledWhenNothingResolves() async {
        let state = await HermesBodyPublisher.HermesState.probeLive(
            baseURL: URL(string: "http://127.0.0.1:8642")!,
            bearerToken: nil,
            dependencies: makeDependencies(
                probe: (available: false, authRejected: false, modelName: nil),
                executable: nil
            )
        )
        XCTAssertEqual(state, .init(installed: false, gatewayReachable: false, version: nil))
    }

    private func makeDependencies(
        probe: (available: Bool, authRejected: Bool, modelName: String?),
        executable: String?,
        onResolveExecutable: @escaping @Sendable () -> Void = {}
    ) -> HermesRuntimeLauncherDependencies {
        HermesRuntimeLauncherDependencies(
            resolveHermesExecutable: {
                onResolveExecutable()
                return executable
            },
            runCommand: { _, _ in "" },
            launchDetached: { _, _ in },
            probeGateway: { _, _ in probe },
            ensureAPIServerEnabled: {},
            readAPIServerKey: { nil }
        )
    }

    // MARK: - HermesBodyRecord presence

    func test_presenceOnlineWithinFreshness() {
        let record = makeRecord(lastHeartbeatAt: Date().addingTimeInterval(-60))
        XCTAssertEqual(record.presence(now: Date(), freshness: 180), .online)
    }

    func test_presenceOfflineBeyondFreshness() {
        let record = makeRecord(lastHeartbeatAt: Date().addingTimeInterval(-200))
        XCTAssertEqual(record.presence(now: Date(), freshness: 180), .offline)
    }

    func test_presenceOfflineWhenNoHeartbeat() {
        let record = makeRecord(lastHeartbeatAt: nil)
        XCTAssertEqual(record.presence(), .offline)
    }

    // MARK: - HermesBodyRecord hardwareSummary

    func test_hardwareSummaryWithChipAndMemory() {
        let record = makeRecord(chipBrand: "Apple M4 Pro", memBytes: 17_179_869_184)
        XCTAssertEqual(record.hardwareSummary, "Apple M4 Pro · 16 GB")
    }

    func test_hardwareSummaryWithChipOnly() {
        let record = makeRecord(chipBrand: "Apple M4 Pro", memBytes: nil)
        XCTAssertEqual(record.hardwareSummary, "Apple M4 Pro")
    }

    func test_hardwareSummaryFallsToHardwareModel() {
        let record = makeRecord(chipBrand: nil, hardwareModel: "mac15,3", memBytes: nil)
        XCTAssertEqual(record.hardwareSummary, "mac15,3")
    }

    func test_hardwareSummaryEmDashWhenUnknown() {
        let record = makeRecord(chipBrand: nil, hardwareModel: nil, memBytes: nil)
        XCTAssertEqual(record.hardwareSummary, "—")
    }

    // MARK: - HermesBodyRecord fromFirestore

    func test_fromFirestoreParsesAllFields() {
        let now = ISO8601DateFormatter().string(from: Date())
        let data: [String: Any] = [
            "id": "relay-host-abc",
            "deviceID": "device-123",
            "displayName": "Studio Hermes",
            "machineName": "Mac Studio",
            "hardware": [
                "hardwareModel": "mac14,13",
                "chipBrand": "Apple M2 Ultra",
                "coresPerformance": 16,
                "coresEfficiency": 4,
                "memBytes": Int64(64_000_000_000)
            ] as [String: Any],
            "hermes": ["installed": true, "gatewayReachable": true] as [String: Any],
            "endpoints": ["pairingConnectionId": "relay-host-abc", "irohNodeId": "node-xyz"] as [String: Any],
            "presence": ["state": "online", "lastHeartbeatAt": now, "wireReachable": false] as [String: Any],
            "capabilities": ["fleet_probe", "hermes_chat"]
        ]
        let record = HermesBodyRecord.fromFirestore(id: "relay-host-abc", data: data)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.displayName, "Studio Hermes")
        XCTAssertEqual(record?.hardwareModel, "mac14,13")
        XCTAssertEqual(record?.chipBrand, "Apple M2 Ultra")
        XCTAssertEqual(record?.hermesInstalled, true)
        XCTAssertEqual(record?.hermesGatewayReachable, true)
        XCTAssertEqual(record?.irohNodeID, "node-xyz")
        XCTAssertEqual(record?.capabilities, ["fleet_probe", "hermes_chat"])
        XCTAssertNotNil(record?.lastHeartbeatAt)
    }

    func test_fromFirestoreFallsBackToDefaultDisplayName() {
        let data: [String: Any] = [
            "deviceID": "dev",
            "machineName": "My Mac"
        ]
        let record = HermesBodyRecord.fromFirestore(id: "body-1", data: data)
        XCTAssertEqual(record?.displayName, "My Mac Hermes")
    }

    func test_fromFirestoreReturnsNilWithoutDeviceID() {
        let data: [String: Any] = ["machineName": "Mac"]
        XCTAssertNil(HermesBodyRecord.fromFirestore(id: "body-1", data: data))
    }

    func test_fromFirestoreToleratesMissingNestedMaps() {
        let data: [String: Any] = [
            "deviceID": "dev",
            "machineName": "Mac"
        ]
        let record = HermesBodyRecord.fromFirestore(id: "body-1", data: data)
        XCTAssertNotNil(record)
        XCTAssertFalse(record?.hermesInstalled ?? true)
        XCTAssertFalse(record?.hermesGatewayReachable ?? true)
        XCTAssertNil(record?.hardwareModel)
        XCTAssertEqual(record?.capabilities, [])
    }

    // MARK: - Helpers

    private func makeRecord(
        lastHeartbeatAt: Date? = nil,
        chipBrand: String? = nil,
        hardwareModel: String? = nil,
        memBytes: Int64? = nil
    ) -> HermesBodyRecord {
        HermesBodyRecord(
            id: "relay-host-test",
            deviceID: "device-test",
            displayName: "Test Hermes",
            machineName: "Test Mac",
            hardwareModel: hardwareModel,
            chipBrand: chipBrand,
            coresPerformance: nil,
            coresEfficiency: nil,
            memBytes: memBytes,
            hermesInstalled: true,
            hermesGatewayReachable: true,
            botCount: nil,
            irohNodeID: nil,
            lastHeartbeatAt: lastHeartbeatAt,
            wireReachable: false,
            capabilities: ["fleet_probe"]
        )
    }
}
