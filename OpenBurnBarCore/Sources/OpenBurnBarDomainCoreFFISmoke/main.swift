import Foundation
import OpenBurnBarDomainCoreFFI

struct UnionManifest: Decodable {
    let coreVersion: String
    let abiVersion: UInt32
    let sourceSha256: String
}

struct ObservedIdentity: Encodable {
    let candidateCommit: String
    let coreVersion: String
    let abiVersion: UInt32
    let sourceSha256: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("domain-core smoke failed: \(message)\n".utf8))
        exit(1)
    }
}

func data(hex: String) -> Data {
    guard hex.count.isMultiple(of: 2) else {
        FileHandle.standardError.write(Data("domain-core smoke failed: invalid hex fixture\n".utf8))
        exit(1)
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else {
            FileHandle.standardError.write(Data("domain-core smoke failed: invalid hex fixture\n".utf8))
            exit(1)
        }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}

let unionManifestURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../crates/openburnbar-domain-core/union-abi-manifest.json")
    .standardizedFileURL
let unionManifest: UnionManifest
do {
    let data = try Data(contentsOf: unionManifestURL)
    unionManifest = try JSONDecoder().decode(UnionManifest.self, from: data)
} catch {
    FileHandle.standardError.write(
        Data("domain-core smoke failed: cannot read union manifest: \(error)\n".utf8)
    )
    exit(1)
}
require(
    OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == unionManifest.abiVersion,
    "unexpected ABI version"
)
require(
    OpenBurnBarDomainCoreFFI.domainCoreVersion() == unionManifest.coreVersion,
    "unexpected crate version"
)
let sourceFingerprint = OpenBurnBarDomainCoreFFI.domainCoreSourceFingerprint()
require(
    sourceFingerprint.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
    "invalid source fingerprint"
)
let expectedSourceFingerprintURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../Vendor/OpenBurnBarDomainCore.xcframework/openburnbar-domain-core-source.sha256")
    .standardizedFileURL
let expectedSourceFingerprint: String
do {
    expectedSourceFingerprint = try String(contentsOf: expectedSourceFingerprintURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
} catch {
    FileHandle.standardError.write(
        Data("domain-core smoke failed: cannot read XCFramework source fingerprint: \(error)\n".utf8)
    )
    exit(1)
}
require(
    expectedSourceFingerprint.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
    "invalid XCFramework source fingerprint"
)
require(
    expectedSourceFingerprint == unionManifest.sourceSha256,
    "XCFramework source fingerprint does not match union manifest"
)
require(sourceFingerprint == expectedSourceFingerprint, "loaded XCFramework source fingerprint mismatch")

if let reportPath = ProcessInfo.processInfo.environment["DOMAIN_CORE_OBSERVED_IDENTITY_REPORT"] {
    let identity = ObservedIdentity(
        candidateCommit: ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "",
        coreVersion: OpenBurnBarDomainCoreFFI.domainCoreVersion(),
        abiVersion: OpenBurnBarDomainCoreFFI.domainCoreAbiVersion(),
        sourceSha256: sourceFingerprint
    )
    do {
        var encoded = try JSONEncoder().encode(identity)
        encoded.append(0x0A)
        try encoded.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("domain-core smoke failed: cannot write observed identity: \(error)\n".utf8))
        exit(1)
    }
}

let safetyCode = try OpenBurnBarDomainCoreFFI.hermesGatewayRelaySafetyCode(
    agentPublicKey: Data(base64Encoded: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=")!,
    phonePublicKey: Data(base64Encoded: "BHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E=")!
)
require(safetyCode == "97AB 6CD8 FEF0 9594 D5ED FAF1 1D10 B6F7", "Hermes safety-code mismatch")

let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../tests/fixtures/domain-core/quota/v1/claude-statusline-input.json")
    .standardizedFileURL

let payload: Data
do {
    payload = try Data(contentsOf: fixtureURL)
} catch {
    FileHandle.standardError.write(Data("domain-core smoke failed: cannot read fixture: \(error)\n".utf8))
    exit(1)
}

let result = OpenBurnBarDomainCoreFFI.parseClaudeStatuslineQuota(payload: payload)
require(result.status == .parsed, "fixture did not parse")
require(result.snapshot.provider == "claudeCode", "unexpected provider")
require(
    result.snapshot.buckets.map(\.key) == [
        "claude-five_hour",
        "claude-seven_day",
        "claude-seven_day_opus"
    ],
    "unexpected bucket keys"
)
let fiveHourUtilization = result.snapshot.buckets[0].usedPercent
require(fiveHourUtilization != nil, "missing five-hour utilization")
require(abs((fiveHourUtilization ?? 0) - 42.5) < 0.000_001, "unexpected five-hour utilization")

do {
    let plaintext = Data("OpenBurnBar".utf8)
    let aad = Data("aad".utf8)
    let sealed = try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmSealCombined(
        plaintext: plaintext,
        key: Data(repeating: 0, count: 32),
        nonce: Data(repeating: 0, count: 12),
        aad: aad
    )
    let opened = try OpenBurnBarDomainCoreFFI.cloudVaultAesGcmOpenCombined(
        combined: sealed,
        key: Data(repeating: 0, count: 32),
        aad: aad
    )
    require(opened == plaintext, "AES-GCM native round-trip mismatch")
} catch {
    FileHandle.standardError.write(Data("domain-core smoke failed: AES-GCM: \(error)\n".utf8))
    exit(1)
}

do {
    let recoveryKey = "abc-defg-hjkm-npq-rst-vwxyz-23456789"
    let vaultKey = Data((0..<32).map(UInt8.init))
    let nonce = Data((0..<12).map(UInt8.init))
    let wrapped = try OpenBurnBarDomainCoreFFI.cloudVaultRecoveryWrapVaultKey(
        vaultKey: vaultKey,
        recoveryKey: recoveryKey,
        nonce: nonce
    )
    require(
        wrapped.verificationHash == "3d3722923f9209d63093b1212a55b5fb5de462c00137ba6d6b46228404873166",
        "recovery verification hash mismatch"
    )
    let recoveredVaultKey = try OpenBurnBarDomainCoreFFI.cloudVaultRecoveryOpenVaultKey(
        combined: wrapped.combined,
        recoveryKey: recoveryKey
    )
    require(recoveredVaultKey == vaultKey, "recovery native round-trip mismatch")

    let publicKey = data(
        hex: "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
            "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
    )
    let sharedSecret = Data((0xa0...0xbf).map(UInt8.init))
    try OpenBurnBarDomainCoreFFI.cloudVaultValidateP256X963PublicKey(publicKey: publicKey)
    let escrowWire = try OpenBurnBarDomainCoreFFI.cloudVaultEscrowSeal(
        plaintext: Data(),
        ephemeralPublicKey: publicKey,
        sharedSecret: sharedSecret,
        nonce: nonce
    )
    let openedEscrowPayload = try OpenBurnBarDomainCoreFFI.cloudVaultEscrowOpen(
        wire: escrowWire,
        sharedSecret: sharedSecret
    )
    require(openedEscrowPayload.isEmpty, "P-256 escrow empty-payload round-trip mismatch")
} catch {
    FileHandle.standardError.write(Data("domain-core smoke failed: C1c: \(error)\n".utf8))
    exit(1)
}

do {
    let oldKey = Data(repeating: 0x71, count: 32)
    let newKey = Data(repeating: 0x72, count: 32)
    let newKeyID = "v1_515a733d7320b35b2117893952f93a94"
    let envelope = CloudVaultDocumentEnvelope(
        kind: .sealedPayload,
        fieldName: "sealedPayload",
        schemaVersion: 2,
        algorithm: "AES-256-GCM",
        keyVersion: 1,
        vaultKeyId: "v1_3e441393404b2085e7a3090a47d377ab",
        nonce: nil,
        ciphertext: nil,
        tag: nil,
        sealedBoxBase64: "ERERERERERERERER/IcMhLA283cnbpRNi2CTKvNBn1ZeDHqbBsvt7oVOgZ2I6DwXeAOM",
        plaintextSha256: nil,
        plaintextHmac: nil,
        integrityHashVersion: nil,
        aad: "OpenBurnBar-CloudVaultSealedPayload-v2",
        hasCreatedAt: false
    )
    let request = CloudVaultDocumentRewrapRequest(
        uid: "userA",
        collection: "cli_agent_mission_requests",
        docId: "requestA",
        documentFieldNames: ["vaultKeyID", "plainStatus", "sealedPayload"],
        envelopes: [envelope],
        resealNoncePlan: [
            CloudVaultResealNonce(
                fieldName: "sealedPayload",
                nonce: Data(repeating: 0x22, count: 12)
            )
        ],
        vaultGeneration: 7,
        rotationJobId: "job-7"
    )
    let result = try OpenBurnBarDomainCoreFFI.cloudVaultRewrapDocument(
        request: request,
        oldKey: oldKey,
        newKey: newKey,
        newVaultKeyId: newKeyID
    )
    require(result.changedFields == ["sealedPayload"], "rewrap changed-field mismatch")
    require(result.companionUpdateIntents.map(\.companionFieldName) == ["vaultKeyID"], "rewrap companion intent mismatch")
    require(result.vaultGenerationUpdate == 7, "rewrap generation intent mismatch")
    require(result.rotationJobIdUpdate == "job-7", "rewrap job intent mismatch")
    require(result.rewrappedEnvelopes.first?.vaultKeyId == newKeyID, "rewrap key id mismatch")
} catch {
    FileHandle.standardError.write(Data("domain-core smoke failed: document rewrap: \(error)\n".utf8))
    exit(1)
}

print("domain-core native smoke passed")
