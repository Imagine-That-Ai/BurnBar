import Foundation
import OpenBurnBarPlatformSupport

enum CloudVaultLegacyDocumentRewrap {
    static func rewrapCloudVaultDocumentLegacy(
        _ data: [String: Any],
        uid: String,
        collection: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobID: String?,
        noncePlan: [CloudVaultDocumentRewrapNonce]
    ) throws -> CloudVaultDocumentRewrapResult {
        var updated = data
        var changedFields: [String] = []
        var nonceIndex = 0

        func nextNonce(for field: String) throws -> Data {
            guard nonceIndex < noncePlan.count,
                  noncePlan[nonceIndex].fieldName == field else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            defer { nonceIndex += 1 }
            return noncePlan[nonceIndex].bytes
        }

        for field in data.keys.sorted() {
            guard let rawMap = data[field] as? [String: Any] else { continue }
            let context = try CloudVaultAADContext(uid: uid, collection: collection, docID: docID, field: field)

            if let envelope = CloudVaultCrypto.sealedPayload(from: rawMap) {
                guard envelope.vaultKeyID != newVaultKeyID else { continue }
                let plaintext = try openPayloadForRewrap(envelope, keyData: oldKeyData, aadContext: context)
                let resealed = try sealPayload(
                    plaintext,
                    keyData: newKeyData,
                    vaultKeyID: newVaultKeyID,
                    aadContext: context,
                    nonce: try nextNonce(for: field)
                )
                updated[field] = try CloudVaultCrypto.firestoreDictionary(resealed)
                applyVaultKeyCompanionUpdates(
                    to: &updated,
                    field: field,
                    newVaultKeyID: newVaultKeyID
                )
                changedFields.append(field)
                continue
            }

            if let envelope = CloudVaultCrypto.decodeSealedText(from: rawMap) {
                let plaintext = try openTextForRewrap(envelope, keyData: oldKeyData, aadContext: context)
                let resealed = try sealText(
                    plaintext,
                    keyData: newKeyData,
                    aadContext: context,
                    nonce: try nextNonce(for: field)
                )
                updated[field] = try CloudVaultCrypto.firestoreDictionary(resealed)
                changedFields.append(field)
                continue
            }

            if let envelope = CloudVaultCrypto.decodeBlobEnvelopeForDocumentRewrap(rawMap) {
                let plaintext = try openBlobForRewrap(envelope, keyData: oldKeyData, aadContext: context)
                let resealed = try sealBlob(
                    plaintext,
                    keyData: newKeyData,
                    aadContext: context,
                    nonce: try nextNonce(for: field)
                )
                var resealedMap = try CloudVaultCrypto.firestoreDictionary(resealed)
                if rawMap.keys.contains("createdAt") {
                    resealedMap["createdAt"] = rawMap["createdAt"]
                }
                updated[field] = resealedMap
                changedFields.append(field)
            }
        }

        guard nonceIndex == noncePlan.count else {
            throw CloudVaultCryptoError.invalidEnvelope
        }

        if changedFields.isEmpty == false {
            if let vaultGeneration {
                updated["vaultGeneration"] = vaultGeneration
            }
            if let rotationJobID {
                updated["rewrapJobId"] = rotationJobID
            }
        }

        return CloudVaultDocumentRewrapResult(data: updated, changedFields: changedFields)
    }

    private static func openTextForRewrap(
        _ envelope: CloudVaultSealedText,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) throws -> String {
        if (envelope.schemaVersion ?? 1) == CloudVaultCrypto.currentSealedTextSchemaVersion {
            return try CloudVaultCrypto.openText(envelope, keyData: keyData, aadContext: aadContext)
        }
        return try CloudVaultCrypto.openText(envelope, keyData: keyData)
    }

    private static func openBlobForRewrap(
        _ envelope: CloudVaultBlobEnvelope,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) throws -> Data {
        if envelope.schemaVersion >= CloudVaultCrypto.currentBlobEnvelopeSchemaVersion,
           envelope.aad != CloudVaultCrypto.blobEnvelopeAADContext {
            return try CloudVaultCrypto.openBlob(envelope, keyData: keyData, aadContext: aadContext)
        }
        return try CloudVaultCrypto.openBlob(envelope, keyData: keyData)
    }

    private static func openPayloadForRewrap(
        _ envelope: CloudVaultSealedPayload,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) throws -> Data {
        if envelope.schemaVersion >= CloudVaultCrypto.currentSealedPayloadSchemaVersion,
           envelope.aad != CloudVaultCrypto.sealedPayloadAADContext {
            return try CloudVaultCrypto.openPayload(envelope, keyData: keyData, aadContext: aadContext)
        }
        return try CloudVaultCrypto.openPayload(envelope, keyData: keyData)
    }

    private static func sealText(
        _ text: String,
        keyData: Data,
        keyVersion: Int = CloudVaultCrypto.currentKeyVersion,
        aadContext: CloudVaultAADContext,
        nonce: Data
    ) throws -> CloudVaultSealedText {
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: Data(text.utf8),
            keyData: keyData,
            nonce: nonce,
            authenticating: aadContext.data
        )
        return CloudVaultSealedText(
            schemaVersion: CloudVaultCrypto.currentSealedTextSchemaVersion,
            algorithm: CloudVaultCrypto.aesGCMAlgorithm,
            keyVersion: keyVersion,
            nonce: sealed.nonce.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            aad: aadContext.stringValue
        )
    }

    private static func sealBlob(
        _ data: Data,
        keyData: Data,
        keyVersion: Int = CloudVaultCrypto.currentKeyVersion,
        aadContext: CloudVaultAADContext,
        nonce: Data
    ) throws -> CloudVaultBlobEnvelope {
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: data,
            keyData: keyData,
            nonce: nonce,
            authenticating: aadContext.data
        )
        return CloudVaultBlobEnvelope(
            schemaVersion: CloudVaultCrypto.currentBlobEnvelopeSchemaVersion,
            keyVersion: keyVersion,
            plaintextHMAC: try CloudVaultCrypto.blobPlaintextHMAC(data, keyData: keyData),
            integrityHashVersion: CloudVaultCrypto.blobIntegrityHashVersion,
            sealedBoxBase64: sealed.combined.base64EncodedString(),
            aad: aadContext.stringValue
        )
    }

    private static func sealPayload(
        _ data: Data,
        keyData: Data,
        vaultKeyID: String,
        keyVersion: Int = CloudVaultCrypto.currentKeyVersion,
        aadContext: CloudVaultAADContext,
        nonce: Data
    ) throws -> CloudVaultSealedPayload {
        let draft = CloudVaultSealedPayload(
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: "",
            aad: aadContext.stringValue
        )
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: data,
            keyData: keyData,
            nonce: nonce,
            authenticating: sealedPayloadAAD(for: draft, aadContext: aadContext)
        )
        return CloudVaultSealedPayload(
            schemaVersion: CloudVaultCrypto.currentSealedPayloadSchemaVersion,
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: sealed.combined.base64EncodedString(),
            aad: draft.aad
        )
    }

    private static func sealedPayloadAAD(
        for envelope: CloudVaultSealedPayload,
        aadContext: CloudVaultAADContext?
    ) -> Data {
        if let aadContext {
            return aadContext.data
        }
        let aad = "\(CloudVaultCrypto.sealedPayloadAADContext)|\(envelope.algorithm)|"
            + "keyVersion=\(envelope.keyVersion)|vaultKeyID=\(envelope.vaultKeyID)"
        return Data(aad.utf8)
    }

    private static func applyVaultKeyCompanionUpdates(
        to data: inout [String: Any],
        field: String,
        newVaultKeyID: String
    ) {
        switch field {
        case "sealedPayload", "sealedReplyPayload":
            if data["vaultKeyID"] != nil {
                data["vaultKeyID"] = newVaultKeyID
            }
        case "sealedStatePayload":
            if data["sealedStateVaultKeyID"] != nil {
                data["sealedStateVaultKeyID"] = newVaultKeyID
            }
        default:
            break
        }
    }
}
