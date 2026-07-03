import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarMedia

private let modelParityGeneratorPath = "OpenBurnBarCore/Tests/OpenBurnBarLinuxCoreFoundationTests/LinuxCoreFoundationTests.swift"

private let fixture = try makeProviderModelParityFixture()
private let data = try PlatformCrypto.canonicalJSONData(fixture)
private let checksum = PlatformCrypto.sha256Hex(data)

try writeIfRequested(data: data, environmentKey: "OPENBURNBAR_MODEL_PARITY_OUTPUT")
try writeIfRequested(data: Data(checksum.utf8), environmentKey: "OPENBURNBAR_MODEL_PARITY_CHECKSUM_OUTPUT")

print("MACOS_MODEL_FIXTURE_SHA256 \(checksum)")
print("MODEL_PARITY_GENERATOR_PATH \(modelParityGeneratorPath)")

private func makeProviderModelParityFixture() throws -> LinuxProviderModelFixture {
    let payload = Data("media".utf8)
    let frame = MediaFrame(
        kind: .videoNAL,
        flags: [.keyframe, .hasCursorMetadata],
        gopID: 7,
        frameIndex: 2,
        presentationTimestampMillis: 123_456_789,
        cursor: .init(x: 12, y: -34),
        payload: payload
    )
    let envelope = try MediaPacketCodec().encode(frame)
    let aad = AADVectors(
        uid: "user-123",
        connectionID: "conn-abc",
        requestID: "req-001",
        hermesRequestSHA256Hex: PlatformCrypto.sha256Hex(HermesRelayCrypto.requestAAD(
            uid: "user-123",
            connectionID: "conn-abc",
            requestID: "req-001"
        )),
        hermesKeySHA256Hex: PlatformCrypto.sha256Hex(HermesRelayCrypto.keyAAD(
            uid: "user-123",
            connectionID: "conn-abc",
            requestID: "req-001"
        )),
        hermesChunkSequence: 3,
        hermesChunkKind: "delta",
        hermesChunkSHA256Hex: PlatformCrypto.sha256Hex(HermesRelayCrypto.chunkAAD(
            uid: "user-123",
            connectionID: "conn-abc",
            requestID: "req-001",
            sequence: 3,
            kind: "delta"
        )),
        piAgentRequestSHA256Hex: PlatformCrypto.sha256Hex(PiAgentRelayCrypto.requestAAD(
            uid: "user-123",
            connectionID: "conn-abc",
            requestID: "req-001"
        ))
    )

    return LinuxProviderModelFixture(
        schema: "openburnbar-core-model-parity-v2",
        generatedBy: modelParityGeneratorPath,
        providers: [.codex, .claudeCode, .openBurnBar].map(ProviderFixture.init(provider:)),
        quotaBuckets: [
            ProviderQuotaBucket(
                name: "codex-primary",
                used: 12,
                limit: 100,
                remaining: 88,
                window: ProviderQuotaWindowKind.rollingHours.rawValue,
                meta: ["label": "Codex primary", "resetsAt": "2026-07-03T02:00:00Z"],
                resetsAt: try date("2026-07-03T02:00:00Z")
            ),
            ProviderQuotaBucket(
                name: "openburnbar-hosted",
                used: 3,
                limit: 10,
                remaining: 7,
                window: ProviderQuotaWindowKind.daily.rawValue,
                meta: ["label": "Hosted agent"],
                resetsAt: try date("2026-07-04T00:00:00Z")
            )
        ],
        themeModes: UIMode.allCases.map(ThemeModeFixture.init(mode:)),
        skins: AppSkin.allCases.map(SkinFixture.init(skin:)),
        dashboardLayouts: DashboardLayout.allCases.map(DashboardLayoutFixture.init(layout:)),
        computerUse: ComputerUseFixture(
            sessionId: "linux-core-session",
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            actionCap: 50,
            sessionTimeoutSeconds: 1_800
        ),
        media: MediaFixture(
            kind: "videoNAL",
            flags: ["keyframe", "hasCursorMetadata"],
            gopID: frame.gopID,
            frameIndex: frame.frameIndex,
            presentationTimestampMillis: frame.presentationTimestampMillis,
            cursor: .init(x: 12, y: -34),
            payloadBase64: payload.base64EncodedString(),
            wireHex: PlatformCrypto.hexString(envelope),
            wireSHA256Hex: PlatformCrypto.sha256Hex(envelope)
        ),
        aadVectors: aad
    )
}

private func date(_ isoString: String) throws -> Date {
    guard let date = ISO8601DateFormatter().date(from: isoString) else {
        throw FixtureGenerationError.invalidDate(isoString)
    }
    return date
}

private func writeIfRequested(data: Data, environmentKey: String) throws {
    guard let path = ProcessInfo.processInfo.environment[environmentKey], path.isEmpty == false else {
        return
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: [.atomic])
}

private enum FixtureGenerationError: Error {
    case invalidDate(String)
}

private struct LinuxProviderModelFixture: Codable {
    var schema: String
    var generatedBy: String
    var providers: [ProviderFixture]
    var quotaBuckets: [ProviderQuotaBucket]
    var themeModes: [ThemeModeFixture]
    var skins: [SkinFixture]
    var dashboardLayouts: [DashboardLayoutFixture]
    var computerUse: ComputerUseFixture
    var media: MediaFixture
    var aadVectors: AADVectors
}

private struct ProviderFixture: Codable {
    var displayName: String
    var persistedToken: String
    var providerID: String
    var quotaSignal: Bool

    init(provider: AgentProvider) {
        self.displayName = provider.rawValue
        self.persistedToken = provider.persistedToken
        self.providerID = provider.providerID.rawValue
        self.quotaSignal = provider.isQuotaSignalProvider
    }
}

private struct ThemeModeFixture: Codable {
    var rawValue: String
    var displayName: String
    var description: String
    var iconName: String

    init(mode: UIMode) {
        self.rawValue = mode.rawValue
        self.displayName = mode.displayName
        self.description = mode.description
        self.iconName = mode.iconName
    }
}

private struct SkinFixture: Codable {
    var rawValue: String
    var displayName: String
    var storageKey: String

    init(skin: AppSkin) {
        self.rawValue = skin.rawValue
        self.displayName = skin.displayName
        self.storageKey = AppSkin.storageKey
    }
}

private struct DashboardLayoutFixture: Codable {
    var rawValue: String
    var displayName: String
    var symbolName: String
    var isKernelForward: Bool
    var storageKey: String

    init(layout: DashboardLayout) {
        self.rawValue = layout.rawValue
        self.displayName = layout.displayName
        self.symbolName = layout.symbolName
        self.isKernelForward = layout.isKernelForward
        self.storageKey = DashboardLayout.storageKey
    }
}

private struct ComputerUseFixture: Codable {
    var sessionId: String
    var mode: String
    var trustMode: String
    var actionCap: Int
    var sessionTimeoutSeconds: Int
}

private struct MediaFixture: Codable {
    struct Cursor: Codable {
        var x: Int16
        var y: Int16
    }

    var kind: String
    var flags: [String]
    var gopID: UInt32
    var frameIndex: UInt32
    var presentationTimestampMillis: UInt64
    var cursor: Cursor
    var payloadBase64: String
    var wireHex: String
    var wireSHA256Hex: String
}

private struct AADVectors: Codable {
    var uid: String
    var connectionID: String
    var requestID: String
    var hermesRequestSHA256Hex: String
    var hermesKeySHA256Hex: String
    var hermesChunkSequence: Int
    var hermesChunkKind: String
    var hermesChunkSHA256Hex: String
    var piAgentRequestSHA256Hex: String
}
