import Foundation
import OpenBurnBarCore
@testable import OpenBurnBar

struct TestConversationVaultKeyProvider: ConversationCloudVaultKeyProviding {
    let keyData: Data

    init(keyData: Data = Data(repeating: 0x42, count: 32)) {
        self.keyData = keyData
    }

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        try resolvedKey()
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        try resolvedKey()
    }

    func resolvedKey() throws -> CloudVaultResolvedKey {
        try CloudVaultResolvedKey(
            keyData: keyData,
            vaultKeyID: CloudVaultCrypto.vaultKeyID(for: keyData)
        )
    }
}
