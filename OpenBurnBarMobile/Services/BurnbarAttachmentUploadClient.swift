import Foundation
import OpenBurnBarKernel
import OpenBurnBarMedia

/// Product path: begin → mint part URLs → PUT with signed headers → compose → finalize.
enum BurnbarAttachmentUploadClient {
    static func uploadFile(
        fileURL: URL,
        deviceId: String,
        session: BurnbarAttachmentTransferSession = BurnbarAttachmentTransferSession()
    ) async throws -> CLIAgentMissionAttachmentRef {
        let byteCount = Int64(
            (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        )
        let digest = try ContentBlake3.hashFile(at: fileURL)
        let begun = try await ComputerUseSecurityCallableClient.beginBurnbarAttachment(
            byteCount: byteCount,
            contentBlake3: digest,
            deviceId: deviceId
        )
        let contentKey = try FileSealAEAD.mintContentKey()
        let header = FileSealAEAD.Header(
            attachmentId: begun.id,
            totalChunks: begun.chunkCount,
            plaintextSize: byteCount,
            contentBlake3: digest
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        for index in 0..<begun.chunkCount {
            let part = handle.readData(ofLength: FileSealAEAD.chunkPlaintextBytes)
            let nonce = try FileSealAEAD.mintNonce()
            let sealed = try FileSealAEAD.sealChunk(
                plaintext: part,
                contentKey: contentKey,
                header: header,
                chunkIndex: UInt64(index),
                nonce: nonce
            )
            var wire = nonce
            wire.append(sealed.ciphertext)
            wire.append(sealed.tag)
            let partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("burnbar-part-\(begun.id)-\(index)")
            try wire.write(to: partURL)
            let signed = try await ComputerUseSecurityCallableClient.mintBurnbarAttachmentPartURL(
                id: begun.id,
                partIndex: index,
                contentLength: Int64(wire.count),
                deviceId: deviceId
            )
            try await session.uploadAwaiting(fileURL: partURL, signedURL: signed)
        }
        try await ComputerUseSecurityCallableClient.composeBurnbarAttachment(id: begun.id, deviceId: deviceId)
        try await ComputerUseSecurityCallableClient.finalizeBurnbarAttachment(id: begun.id, deviceId: deviceId)
        return CLIAgentMissionAttachmentRef(
            id: begun.id,
            contentBlake3: digest,
            displayName: fileURL.lastPathComponent,
            byteCount: byteCount,
            transport: "cloud",
            contentKeyBase64: contentKey.base64EncodedString()
        )
    }
}
