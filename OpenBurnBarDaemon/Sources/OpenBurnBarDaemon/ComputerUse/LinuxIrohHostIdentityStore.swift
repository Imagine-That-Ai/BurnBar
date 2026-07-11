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
}

enum LinuxIrohHostIdentityStoreError: Error, Equatable, Sendable {
    case corruptSecret(String)
    case secretStoreUnavailable
}

struct LinuxIrohHostIdentityStore: LinuxIrohHostIdentityProviding, Sendable {
    static let endpointSecretID = "iroh-host-endpoint-identity-v1"
    static let pairingSecretID = "iroh-host-pairing-signing-key-v1"

    private let custodian: LinuxSecretCustodian

    init(custodian: LinuxSecretCustodian = LinuxSecretStoreFactory.production()) {
        self.custodian = custodian
    }

    func loadOrCreate() throws -> LinuxIrohHostIdentity {
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
