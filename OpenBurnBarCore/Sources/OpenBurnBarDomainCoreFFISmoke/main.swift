import Foundation
import OpenBurnBarDomainCoreFFI

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

require(OpenBurnBarDomainCoreFFI.domainCoreAbiVersion() == 2, "unexpected ABI version")
require(!OpenBurnBarDomainCoreFFI.domainCoreVersion().isEmpty, "empty crate version")

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

print("domain-core native smoke passed")
