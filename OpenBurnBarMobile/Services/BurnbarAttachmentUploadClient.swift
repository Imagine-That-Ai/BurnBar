import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

/// Product path: begin → mint part URLs → PUT with signed headers → compose → finalize.
enum BurnbarAttachmentUploadClient {
    static func uploadFile(
        fileURL: URL,
        deviceId: String,
        session: BurnbarAttachmentTransferSession = BurnbarAttachmentTransferSession()
    ) async throws -> CLIAgentMissionAttachmentRef {
        let data = try Data(contentsOf: fileURL)
        let digest = ContentBlake3.hash(data)
        let byteCount = Int64(data.count)
        let begun = try await ComputerUseSecurityCallableClient.beginBurnbarAttachment(
            byteCount: byteCount,
            contentBlake3: digest,
            deviceId: deviceId
        )
        let chunk = Int64(FileSealAEAD.chunkPlaintextBytes)
        for index in 0..<begun.chunkCount {
            let start = Int(Int64(index) * chunk)
            let end = min(data.count, start + Int(chunk))
            let part = data.subdata(in: start..<end)
            let partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("burnbar-part-\(begun.id)-\(index)")
            try part.write(to: partURL)
            let signed = try await ComputerUseSecurityCallableClient.mintBurnbarAttachmentPartURL(
                id: begun.id,
                partIndex: index,
                contentLength: Int64(part.count),
                deviceId: deviceId
            )
            _ = session.uploadFile(fileURL: partURL, signedURL: signed, partKey: "\(begun.id)/\(index)")
        }
        try await ComputerUseSecurityCallableClient.composeBurnbarAttachment(id: begun.id, deviceId: deviceId)
        try await ComputerUseSecurityCallableClient.finalizeBurnbarAttachment(id: begun.id, deviceId: deviceId)
        return CLIAgentMissionAttachmentRef(
            id: begun.id,
            contentBlake3: digest,
            displayName: fileURL.lastPathComponent,
            byteCount: byteCount,
            transport: "cloud"
        )
    }
}
