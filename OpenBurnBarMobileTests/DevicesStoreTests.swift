import CryptoKit
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class DevicesStoreTests: XCTestCase {
    func testLinuxAppCheckDeviceListBlocksCallableWhenUIDChangesAfterBind() async {
        var authenticatedUID = "original-user"
        var callableInvoked = false
        let dependencies = ComputerUseSecurityCallableClient.LinuxAppCheckDeviceListDependencies(
            authenticatedUID: { authenticatedUID },
            bindAppCheckAttestation: { authenticatedUID = "replacement-user" },
            callListDevices: { _ in
                callableInvoked = true
                return ["ok": true, "devices": []]
            }
        )

        do {
            _ = try await ComputerUseSecurityCallableClient.listLinuxAppCheckDevices(
                approverDeviceId: "ipad-approver",
                dependencies: dependencies
            )
            XCTFail("Expected UID drift after binding to reject the request")
        } catch ComputerUseSecurityCallableClient.ClientError.notAuthenticated {
            XCTAssertFalse(callableInvoked)
        } catch {
            XCTFail("Expected notAuthenticated, got \(error)")
        }
    }

    func testLinuxAppCheckDeviceListBlocksParsingWhenUIDChangesAfterCallable() async {
        var authenticatedUID = "original-user"
        var callableInvoked = false
        let dependencies = ComputerUseSecurityCallableClient.LinuxAppCheckDeviceListDependencies(
            authenticatedUID: { authenticatedUID },
            bindAppCheckAttestation: {},
            callListDevices: { _ in
                callableInvoked = true
                authenticatedUID = "replacement-user"
                return ["malformed": "response"]
            }
        )

        do {
            _ = try await ComputerUseSecurityCallableClient.listLinuxAppCheckDevices(
                approverDeviceId: "ipad-approver",
                dependencies: dependencies
            )
            XCTFail("Expected UID drift after the callable to reject its response")
        } catch ComputerUseSecurityCallableClient.ClientError.notAuthenticated {
            XCTAssertTrue(callableInvoked)
        } catch {
            XCTFail("Expected notAuthenticated before response parsing, got \(error)")
        }
    }

    func testLinuxAppCheckCallableParserAcceptsOnlyPublicReviewMaterial() throws {
        let identity = Self.linuxIdentity(seed: 0)
        let devices = try ComputerUseSecurityCallableClient.parseLinuxAppCheckDevicesResponse([
            "ok": true,
            "devices": [[
                "deviceId": identity.deviceId,
                "deviceName": "Workstation",
                "platform": "Linux",
                "publicKeyBase64": identity.publicKeyBase64,
                "safetyFingerprint": identity.fingerprint,
                "trustState": "pending",
                "createdAtMillis": NSNumber(value: 1_000)
            ]]
        ])

        XCTAssertEqual(devices, [
            LinuxAppCheckDeviceRecord(
                deviceId: identity.deviceId,
                deviceName: "Workstation",
                safetyFingerprint: identity.fingerprint,
                trustState: .pending,
                createdAtMillis: 1_000
            )
        ])
    }

    func testLinuxAppCheckCallableParserRejectsMalformedRecords() {
        XCTAssertThrowsError(
            try ComputerUseSecurityCallableClient.parseLinuxAppCheckDevicesResponse([
                "ok": true,
                "devices": [[
                    "deviceId": "linux_abc",
                    "deviceName": "Workstation",
                    "platform": "Linux",
                    "trustState": "pending",
                    "createdAtMillis": 1_000
                ]]
            ])
        )
    }

    func testLinuxAppCheckCallableParserRejectsKeyFingerprintOrDeviceIDMismatch() {
        let identity = Self.linuxIdentity(seed: 0)
        let otherIdentity = Self.linuxIdentity(seed: 1)
        for mutation in [
            ["deviceId": otherIdentity.deviceId, "safetyFingerprint": identity.fingerprint],
            ["deviceId": identity.deviceId, "safetyFingerprint": otherIdentity.fingerprint]
        ] {
            XCTAssertThrowsError(
                try ComputerUseSecurityCallableClient.parseLinuxAppCheckDevicesResponse([
                    "ok": true,
                    "devices": [[
                        "deviceId": mutation["deviceId"]!,
                        "deviceName": "Workstation",
                        "platform": "Linux",
                        "publicKeyBase64": identity.publicKeyBase64,
                        "safetyFingerprint": mutation["safetyFingerprint"]!,
                        "trustState": "pending",
                        "createdAtMillis": 1_000
                    ]]
                ])
            )
        }
    }

    func testLinuxAppCheckMutationDescriptorsBindTargetSignerActionAndDecision() {
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.linuxAppCheckTrustMutationDescriptor(
                deviceId: "linux-target",
                approverDeviceId: "ipad-signer",
                approve: true
            ),
            .init(
                callableName: "approveLinuxAppCheckDevice",
                actionKind: "linux_app_check_device_approve",
                subjectId: "linux-target",
                deviceId: "linux-target",
                approverDeviceId: "ipad-signer",
                approve: true
            )
        )
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.linuxAppCheckTrustMutationDescriptor(
                deviceId: "linux-target",
                approverDeviceId: "ipad-signer",
                approve: false
            ),
            .init(
                callableName: "revokeLinuxAppCheckDevice",
                actionKind: "linux_app_check_device_revoke",
                subjectId: "linux-target",
                deviceId: "linux-target",
                approverDeviceId: "ipad-signer",
                approve: false
            )
        )
    }

    func testLinuxAppCheckDevicesLoadPendingFirstWithCurrentDeviceAuthority() async {
        let manager = FakeLinuxAppCheckDeviceManager(devices: [
            Self.linuxDevice(id: "approved", state: .approved, createdAt: 2_000),
            Self.linuxDevice(id: "pending-old", state: .pending, createdAt: 1_000),
            Self.linuxDevice(id: "pending-new", state: .pending, createdAt: 3_000),
            Self.linuxDevice(id: "revoked", state: .revoked, createdAt: 4_000)
        ])
        let store = DevicesStore(
            reader: FakeDevicesCloudReader(devices: [Self.currentDevice()]),
            trustGateway: FakeDeviceTrustGateway(),
            linuxAppCheckManager: manager
        )

        await store.load()

        XCTAssertEqual(
            store.linuxAppCheckDevices.map(\.id),
            ["pending-new", "pending-old", "approved", "revoked"]
        )
        let calls = await manager.recordedCalls()
        XCTAssertEqual(calls, [.list(approverDeviceId: "ipad-current")])
        XCTAssertNil(store.linuxAppCheckError)
    }

    func testLinuxAppCheckApproveAndRevokeUseTrustedCurrentDeviceAndRefresh() async throws {
        let pending = Self.linuxDevice(id: "linux-pending", state: .pending, createdAt: 1_000)
        let manager = FakeLinuxAppCheckDeviceManager(devices: [pending])
        let store = DevicesStore(
            reader: FakeDevicesCloudReader(devices: [Self.currentDevice()]),
            trustGateway: FakeDeviceTrustGateway(),
            linuxAppCheckManager: manager
        )
        await store.load()

        await store.approveLinuxAppCheckDevice(pending)
        let approved = try XCTUnwrap(store.linuxAppCheckDevices.first)
        await store.revokeLinuxAppCheckDevice(approved)

        XCTAssertEqual(try XCTUnwrap(store.linuxAppCheckDevices.first).trustState, .revoked)
        let calls = await manager.recordedCalls()
        XCTAssertEqual(calls, [
            .list(approverDeviceId: "ipad-current"),
            .approve(deviceId: "linux-pending", approverDeviceId: "ipad-current"),
            .list(approverDeviceId: "ipad-current"),
            .revoke(deviceId: "linux-pending", approverDeviceId: "ipad-current"),
            .list(approverDeviceId: "ipad-current")
        ])
    }

    func testLinuxAppCheckMutationsAreGloballySerialized() async {
        let pending = Self.linuxDevice(id: "linux-pending", state: .pending, createdAt: 2_000)
        let approved = Self.linuxDevice(id: "linux-approved", state: .approved, createdAt: 1_000)
        let manager = BlockingLinuxAppCheckDeviceManager(devices: [pending, approved])
        let store = DevicesStore(
            reader: FakeDevicesCloudReader(devices: [Self.currentDevice()]),
            trustGateway: FakeDeviceTrustGateway(),
            linuxAppCheckManager: manager
        )
        await store.load()

        let firstMutation = Task { await store.approveLinuxAppCheckDevice(pending) }
        await manager.waitForMutationStart()
        await store.revokeLinuxAppCheckDevice(approved)

        XCTAssertEqual(
            store.linuxAppCheckError,
            "Finish the current Linux device update before starting another."
        )
        let calls = await manager.recordedCalls()
        XCTAssertEqual(calls, [
            .list(approverDeviceId: "ipad-current"),
            .approve(deviceId: "linux-pending", approverDeviceId: "ipad-current")
        ])

        await manager.releaseMutation()
        await firstMutation.value
    }

    func testSupersededLinuxDeviceLoadCannotOverwriteNewerResult() async {
        let manager = ControlledLinuxAppCheckDeviceManager()
        let store = DevicesStore(
            reader: FakeDevicesCloudReader(devices: [Self.currentDevice()]),
            trustGateway: FakeDeviceTrustGateway(),
            linuxAppCheckManager: manager
        )

        let olderLoad = Task { await store.load() }
        await manager.waitForCallCount(1)
        let newerLoad = Task { await store.loadLinuxAppCheckDevices() }
        await manager.waitForCallCount(2)

        await manager.complete(
            call: 1,
            with: [Self.linuxDevice(id: "newer", state: .approved, createdAt: 2_000)]
        )
        await newerLoad.value
        await manager.complete(
            call: 0,
            with: [Self.linuxDevice(id: "stale", state: .pending, createdAt: 1_000)]
        )
        await olderLoad.value

        XCTAssertEqual(store.linuxAppCheckDevices.map(\.id), ["newer"])
    }

    private static func currentDevice() -> DeviceRecord {
        DeviceRecord(
            id: "ipad-current",
            displayName: "Alberto iPad",
            platform: "iPadOS",
            lastSeen: Date(),
            trustState: .current,
            isCurrentDevice: true
        )
    }

    private static func linuxDevice(
        id: String,
        state: LinuxAppCheckDeviceTrustState,
        createdAt: Int64
    ) -> LinuxAppCheckDeviceRecord {
        LinuxAppCheckDeviceRecord(
            deviceId: id,
            deviceName: id,
            safetyFingerprint: "A1B2C3D4",
            trustState: state,
            createdAtMillis: createdAt
        )
    }

    private static func linuxIdentity(seed: UInt8) -> (
        deviceId: String,
        fingerprint: String,
        publicKeyBase64: String
    ) {
        let publicKey = Data((0..<32).map { UInt8($0) &+ seed })
        let digest = SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
        let uppercase = digest.uppercased()
        let fingerprint = stride(from: 0, to: uppercase.count, by: 4).map { offset in
            let start = uppercase.index(uppercase.startIndex, offsetBy: offset)
            let end = uppercase.index(start, offsetBy: 4)
            return String(uppercase[start..<end])
        }.joined(separator: " ")
        return ("linux_\(digest)", fingerprint, publicKey.base64EncodedString())
    }

    func testDisplayDevicesPreserveDistinctRegistrationsWithMatchingNamesAndPlatforms() async {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let reader = FakeDevicesCloudReader(devices: [
            DeviceRecord(
                id: "iphone-current",
                displayName: "Alberto iPhone",
                platform: "iOS",
                lastSeen: now,
                trustState: .current,
                isCurrentDevice: true
            ),
            DeviceRecord(
                id: "iphone-old",
                displayName: "Alberto iPhone",
                platform: "iOS",
                lastSeen: now.addingTimeInterval(-600),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "macbook-old",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-3_600),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "macbook-new",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-60),
                trustState: .pending
            ),
            DeviceRecord(
                id: "mac-mini",
                displayName: "Alberto Mac mini",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-120),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "samsung",
                displayName: "Samsung",
                platform: "Android",
                lastSeen: now.addingTimeInterval(-180),
                trustState: .trusted
            )
        ])
        let store = DevicesStore(reader: reader, trustGateway: FakeDeviceTrustGateway())

        await store.load()

        XCTAssertEqual(
            store.devices.map(\.id),
            ["iphone-current", "macbook-new", "mac-mini", "samsung", "iphone-old", "macbook-old"]
        )
        XCTAssertEqual(store.devices.count, 6)
        XCTAssertEqual(
            store.otherDevices.map(\.id),
            ["macbook-new", "mac-mini", "samsung", "iphone-old", "macbook-old"]
        )
    }

    func testHundredsOfSameNameRegistrationsRemainIndividuallyManageable() async {
        let now = Date(timeIntervalSinceReferenceDate: 15_000)
        let stalePhones = (0..<300).map { index in
            DeviceRecord(
                id: "iphone-stale-\(index)",
                displayName: "Alberto iPhone",
                platform: "iOS",
                lastSeen: now.addingTimeInterval(TimeInterval(-index - 1)),
                trustState: .trusted
            )
        }
        let reader = FakeDevicesCloudReader(devices: [
            DeviceRecord(
                id: "iphone-current",
                displayName: "Alberto iPhone",
                platform: "iOS",
                lastSeen: now,
                trustState: .current,
                isCurrentDevice: true
            ),
            DeviceRecord(
                id: "macbook",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-60),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "mac-mini",
                displayName: "Alberto Mac mini",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-120),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "samsung",
                displayName: "Samsung",
                platform: "Android",
                lastSeen: now.addingTimeInterval(-180),
                trustState: .trusted
            )
        ] + stalePhones)
        let store = DevicesStore(reader: reader, trustGateway: FakeDeviceTrustGateway())

        await store.load()

        XCTAssertEqual(store.devices.count, 304)
        XCTAssertEqual(Set(store.devices.map(\.id)).count, 304)
        XCTAssertTrue(store.devices.map(\.id).contains("iphone-stale-299"))
    }

    func testApprovePendingDeviceUsesGatewayAndRefreshes() async throws {
        let targetKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let target = DeviceRecord(
            id: "pending-mac",
            displayName: "Pending Mac",
            platform: "macOS",
            trustState: .pending,
            publicKeyFingerprint: Data(SHA256.hash(data: targetKey)).base64EncodedString(),
            publicKeyData: targetKey.base64EncodedString()
        )
        let reader = FakeDevicesCloudReader(devices: [Self.currentDevice(), target])
        let gateway = FakeDeviceTrustGateway()
        let store = DevicesStore(reader: reader, trustGateway: gateway)
        await store.load()

        await store.approve(target)

        XCTAssertEqual(gateway.approvedDeviceIDs, ["pending-mac"])
        XCTAssertEqual(reader.loadDevicesCallCount, 2)
        XCTAssertNil(store.lastError)
    }

    func testApproveFailsClosedWithoutVerifiedSafetyCode() async {
        let target = DeviceRecord(
            id: "pending-mac",
            displayName: "Pending Mac",
            platform: "macOS",
            trustState: .pending
        )
        let reader = FakeDevicesCloudReader(devices: [Self.currentDevice(), target])
        let gateway = FakeDeviceTrustGateway()
        let store = DevicesStore(reader: reader, trustGateway: gateway)
        await store.load()

        await store.approve(target)

        XCTAssertTrue(gateway.approvedDeviceIDs.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testTrustedAndPendingSameNameDevicesRemainDistinct() async {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let reader = FakeDevicesCloudReader(devices: [
            DeviceRecord(
                id: "trusted-mac",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-3_600),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "pending-mac",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now,
                trustState: .pending
            )
        ])
        let store = DevicesStore(reader: reader, trustGateway: FakeDeviceTrustGateway())

        await store.load()

        XCTAssertEqual(store.devices.map(\.id), ["pending-mac", "trusted-mac"])
    }

    func testRevokeUsesSelectedStableDeviceIdentityWhenNamesMatch() async {
        let first = DeviceRecord(
            id: "iphone-registration-a",
            displayName: "Alberto iPhone",
            platform: "iOS",
            trustState: .trusted
        )
        let second = DeviceRecord(
            id: "iphone-registration-b",
            displayName: "Alberto iPhone",
            platform: "iOS",
            trustState: .trusted
        )
        let reader = FakeDevicesCloudReader(devices: [first, second])
        let gateway = FakeDeviceTrustGateway()
        let store = DevicesStore(reader: reader, trustGateway: gateway)
        await store.load()

        await store.revoke(second)

        XCTAssertEqual(gateway.revokedDeviceIDs, ["iphone-registration-b"])
    }
}

private actor FakeLinuxAppCheckDeviceManager: LinuxAppCheckDeviceManaging {
    enum Call: Sendable, Equatable {
        case list(approverDeviceId: String)
        case approve(deviceId: String, approverDeviceId: String)
        case revoke(deviceId: String, approverDeviceId: String)
    }

    private var devices: [LinuxAppCheckDeviceRecord]
    private var calls: [Call] = []

    init(devices: [LinuxAppCheckDeviceRecord]) {
        self.devices = devices
    }

    func list(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord] {
        calls.append(.list(approverDeviceId: approverDeviceId))
        return devices
    }

    func approve(deviceId: String, approverDeviceId: String) async throws {
        calls.append(.approve(deviceId: deviceId, approverDeviceId: approverDeviceId))
        devices = devices.map { device in
            guard device.id == deviceId else { return device }
            return LinuxAppCheckDeviceRecord(
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                safetyFingerprint: device.safetyFingerprint,
                trustState: .approved,
                createdAtMillis: device.createdAtMillis,
                approvedAtMillis: 2_000
            )
        }
    }

    func revoke(deviceId: String, approverDeviceId: String) async throws {
        calls.append(.revoke(deviceId: deviceId, approverDeviceId: approverDeviceId))
        devices = devices.map { device in
            guard device.id == deviceId else { return device }
            return LinuxAppCheckDeviceRecord(
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                safetyFingerprint: device.safetyFingerprint,
                trustState: .revoked,
                createdAtMillis: device.createdAtMillis,
                approvedAtMillis: device.approvedAtMillis,
                revokedAtMillis: 3_000
            )
        }
    }

    func recordedCalls() -> [Call] { calls }
}

private actor ControlledLinuxAppCheckDeviceManager: LinuxAppCheckDeviceManaging {
    private var continuations: [Int: CheckedContinuation<[LinuxAppCheckDeviceRecord], Error>] = [:]
    private var callCount = 0

    func list(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord] {
        let index = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func approve(deviceId: String, approverDeviceId: String) async throws {}
    func revoke(deviceId: String, approverDeviceId: String) async throws {}

    func waitForCallCount(_ expected: Int) async {
        while callCount < expected {
            await Task.yield()
        }
    }

    func complete(call index: Int, with devices: [LinuxAppCheckDeviceRecord]) {
        continuations.removeValue(forKey: index)?.resume(returning: devices)
    }
}

private actor BlockingLinuxAppCheckDeviceManager: LinuxAppCheckDeviceManaging {
    enum Call: Sendable, Equatable {
        case list(approverDeviceId: String)
        case approve(deviceId: String, approverDeviceId: String)
        case revoke(deviceId: String, approverDeviceId: String)
    }

    private let devices: [LinuxAppCheckDeviceRecord]
    private var calls: [Call] = []
    private var mutationStarted = false
    private var mutationContinuation: CheckedContinuation<Void, Never>?

    init(devices: [LinuxAppCheckDeviceRecord]) {
        self.devices = devices
    }

    func list(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord] {
        calls.append(.list(approverDeviceId: approverDeviceId))
        return devices
    }

    func approve(deviceId: String, approverDeviceId: String) async throws {
        calls.append(.approve(deviceId: deviceId, approverDeviceId: approverDeviceId))
        mutationStarted = true
        await withCheckedContinuation { continuation in
            mutationContinuation = continuation
        }
    }

    func revoke(deviceId: String, approverDeviceId: String) async throws {
        calls.append(.revoke(deviceId: deviceId, approverDeviceId: approverDeviceId))
    }

    func waitForMutationStart() async {
        while !mutationStarted {
            await Task.yield()
        }
    }

    func releaseMutation() {
        mutationContinuation?.resume()
        mutationContinuation = nil
    }

    func recordedCalls() -> [Call] { calls }
}

@MainActor
private final class FakeDevicesCloudReader: CloudReader {
    private let devices: [DeviceRecord]
    private(set) var loadDevicesCallCount = 0

    init(devices: [DeviceRecord]) {
        self.devices = devices
    }

    func loadSyncStatus() async throws -> CloudSyncStatusSnapshot {
        CloudSyncStatusSnapshot()
    }

    func loadProviderSummaries() async throws -> [ProviderConnectionDoc] {
        []
    }

    func loadDevices() async throws -> [DeviceRecord] {
        loadDevicesCallCount += 1
        return devices
    }

    func loadAvailableEnvelopes() async throws -> [AvailableEnvelope] {
        []
    }

    func loadUnsupportedEnvelopes() async throws -> [UnsupportedEnvelope] {
        []
    }

    func loadImportHistory() async throws -> [ImportHistoryEntry] {
        []
    }
}

@MainActor
private final class FakeDeviceTrustGateway: DeviceTrustGateway {
    private(set) var approvedDeviceIDs: [String] = []
    private(set) var revokedDeviceIDs: [String] = []

    func bootstrapApproveSelf() async throws {}
    func approve(deviceID: String) async throws {
        approvedDeviceIDs.append(deviceID)
    }
    func renameSelf(_ newName: String) async throws {}
    func revoke(deviceID: String) async throws {
        revokedDeviceIDs.append(deviceID)
    }
}
