#if os(Linux)
import Foundation
import OpenBurnBarIrohRelay
import OpenBurnBarKernel
import OpenBurnBarLinuxSecurity

struct LinuxIrohHostIdentity: Sendable {
    let endpointSecret: IrohSecretKeyMaterial
    let pairingKeypair: IrohPairingKeypair
}

protocol LinuxIrohHostIdentityProviding: Sendable {
    func loadOrCreate() throws -> LinuxIrohHostIdentity
    func rotate() throws -> LinuxIrohHostIdentity
}

extension LinuxIrohHostIdentityProviding {
    func rotate() throws -> LinuxIrohHostIdentity {
        throw LinuxIrohHostIdentityStoreError.rotationUnsupported
    }
}

enum LinuxIrohHostIdentityStoreError: Error, Equatable, Sendable {
    case corruptSecret(String)
    case rotationUnsupported
    case secretStoreUnavailable
}

struct LinuxIrohHostIdentityStore: LinuxIrohHostIdentityProviding, Sendable {
    static let endpointSecretID = "iroh-host-endpoint-identity-v1"
    static let pairingSecretID = "iroh-host-pairing-signing-key-v1"
    static let combinedSecretID = "iroh-host-identity-v2"

    private struct StoredIdentity: Codable {
        static let schemaVersion = 1

        let version: Int
        let endpointSecretBase64: String
        let pairingSecretBase64: String
    }

    private let custodian: LinuxSecretCustodian

    init(custodian: LinuxSecretCustodian = LinuxSecretStoreFactory.production()) {
        self.custodian = custodian
    }

    func loadOrCreate() throws -> LinuxIrohHostIdentity {
        do {
            return try loadCombinedIdentity()
        } catch LinuxSecretStoreError.missingSecret {
            // Existing installs keep their v1 identity until an explicit rotation.
        } catch let error as LinuxIrohHostIdentityStoreError {
            throw error
        } catch {
            throw LinuxIrohHostIdentityStoreError.secretStoreUnavailable
        }
        let endpointData = try loadOrCreateBytes(
            id: Self.endpointSecretID,
            generator: { IrohSecretKeyMaterial.generate().raw }
        )
        let pairingData = try loadOrCreateBytes(
            id: Self.pairingSecretID,
            generator: { PlatformCrypto.ed25519PrivateKey().rawRepresentation }
        )
        guard endpointData.count == 32 else {
            throw LinuxIrohHostIdentityStoreError.corruptSecret(Self.endpointSecretID)
        }
        let signingKey: PlatformEd25519SigningMaterial
        do {
            signingKey = try PlatformCrypto.ed25519PrivateKey(rawRepresentation: pairingData)
        } catch {
            throw LinuxIrohHostIdentityStoreError.corruptSecret(Self.pairingSecretID)
        }
        return LinuxIrohHostIdentity(
            endpointSecret: IrohSecretKeyMaterial(raw: endpointData),
            pairingKeypair: IrohPairingKeypair(signingKey: signingKey)
        )
    }

    func rotate() throws -> LinuxIrohHostIdentity {
        let endpointData = IrohSecretKeyMaterial.generate().raw
        let pairingData = PlatformCrypto.ed25519PrivateKey().rawRepresentation
        guard endpointData.count == 32, pairingData.count == 32 else {
            throw LinuxIrohHostIdentityStoreError.corruptSecret(Self.combinedSecretID)
        }
        let stored = StoredIdentity(
            version: StoredIdentity.schemaVersion,
            endpointSecretBase64: endpointData.base64EncodedString(),
            pairingSecretBase64: pairingData.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(stored)
            guard data.count <= 4_096, let value = String(data: data, encoding: .utf8) else {
                throw LinuxIrohHostIdentityStoreError.corruptSecret(Self.combinedSecretID)
            }
            _ = try custodian.storeHighValueSecret(
                value,
                id: Self.combinedSecretID,
                secretClass: .signalIdentityKey
            )
            let identity = try loadCombinedIdentity()
            try? custodian.deleteHighValueSecret(id: Self.endpointSecretID, secretClass: .signalIdentityKey)
            try? custodian.deleteHighValueSecret(id: Self.pairingSecretID, secretClass: .signalIdentityKey)
            return identity
        } catch let error as LinuxIrohHostIdentityStoreError {
            throw error
        } catch {
            throw LinuxIrohHostIdentityStoreError.secretStoreUnavailable
        }
    }

    private func loadCombinedIdentity() throws -> LinuxIrohHostIdentity {
        let record = try custodian.requireHighValueSecret(
            id: Self.combinedSecretID,
            secretClass: .signalIdentityKey
        )
        guard record.secret.utf8.count <= 4_096,
              let data = record.secret.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
              stored.version == StoredIdentity.schemaVersion,
              let endpointData = Data(base64Encoded: stored.endpointSecretBase64), endpointData.count == 32,
              let pairingData = Data(base64Encoded: stored.pairingSecretBase64), pairingData.count == 32 else {
            throw LinuxIrohHostIdentityStoreError.corruptSecret(Self.combinedSecretID)
        }
        let signingKey: PlatformEd25519SigningMaterial
        do {
            signingKey = try PlatformCrypto.ed25519PrivateKey(rawRepresentation: pairingData)
        } catch {
            throw LinuxIrohHostIdentityStoreError.corruptSecret(Self.combinedSecretID)
        }
        return LinuxIrohHostIdentity(
            endpointSecret: IrohSecretKeyMaterial(raw: endpointData),
            pairingKeypair: IrohPairingKeypair(signingKey: signingKey)
        )
    }

    private func loadOrCreateBytes(
        id: String,
        generator: () -> Data
    ) throws -> Data {
        do {
            let record = try custodian.requireHighValueSecret(id: id, secretClass: .signalIdentityKey)
            guard let data = Data(base64Encoded: record.secret), data.count == 32 else {
                throw LinuxIrohHostIdentityStoreError.corruptSecret(id)
            }
            return data
        } catch LinuxSecretStoreError.missingSecret {
            let fresh = generator()
            guard fresh.count == 32 else {
                throw LinuxIrohHostIdentityStoreError.corruptSecret(id)
            }
            do {
                _ = try custodian.storeHighValueSecret(
                    fresh.base64EncodedString(),
                    id: id,
                    secretClass: .signalIdentityKey
                )
                let readback = try custodian.requireHighValueSecret(id: id, secretClass: .signalIdentityKey)
                guard let persisted = Data(base64Encoded: readback.secret), persisted == fresh else {
                    throw LinuxIrohHostIdentityStoreError.corruptSecret(id)
                }
                return persisted
            } catch let error as LinuxIrohHostIdentityStoreError {
                throw error
            } catch {
                throw LinuxIrohHostIdentityStoreError.secretStoreUnavailable
            }
        } catch let error as LinuxIrohHostIdentityStoreError {
            throw error
        } catch {
            throw LinuxIrohHostIdentityStoreError.secretStoreUnavailable
        }
    }
}
#endif
