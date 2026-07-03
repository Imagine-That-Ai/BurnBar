import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

/// Off-main-thread decode path for inbound Mercury mirror frames. Keeps
/// base64 expansion, chunk reassembly, AEAD open, and packet codec work
/// off the UI thread so the control-stream read loop stays responsive.
///
/// Seal key / established flags are passed per call (not stored on the actor)
/// so a `mediaFrameSealKey` didSet cannot race an accepted-ack update and
/// incorrectly drop plaintext or sealed frames.
actor MediaMirrorFrameProcessor {
    enum DecodedFrame: Sendable {
        case v1(MediaFrame)
        case v2(MediaFrameV2)
    }

    private var frameChunkAssembler = MediaFrameChunkAssembler()
    private let mediaPacketCodec = MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes)
    private let mediaFrameV2Codec = MediaFrameV2Codec()
    private let frameSealAEAD = MediaFrameAEAD()

    func resetChunkAssembler() {
        frameChunkAssembler = MediaFrameChunkAssembler()
    }

    func processStreamFrame(
        encodedFrameBase64: String,
        frameChunk: HermesRealtimeRelayMediaFrameChunk?,
        sealedFramePosition: HermesRealtimeRelaySealedMediaFramePosition?,
        sealKey: SymmetricKey?,
        sealEstablished: Bool
    ) -> DecodedFrame? {
        guard let chunkData = Data(base64Encoded: encodedFrameBase64),
              var data = frameChunkAssembler.accept(chunk: frameChunk, bytes: chunkData) else {
            return nil
        }

        if MediaFrameAEAD.isSealedEnvelope(data) {
            guard let sealKey,
                  let position = sealedFramePosition,
                  let opened = try? frameSealAEAD.open(
                    envelope: data,
                    key: sealKey,
                    streamClass: MediaStreamClass.screenVideo.rawValue,
                    kind: position.kind,
                    gopID: position.gopId,
                    frameIndex: position.frameIndex
                  ) else {
                return nil
            }
            data = opened
        } else if sealEstablished {
            return nil
        }

        do {
            if MediaFrameV2Codec.isEncodedEnvelope(data) {
                let decoded = try mediaFrameV2Codec.decode(data).frame
                return .v2(decoded)
            }
            let decoded = try mediaPacketCodec.decode(data).frame
            return .v1(decoded)
        } catch {
            return nil
        }
    }
}

/// Reassembles chunked media frames. Bounded to a small number of in-flight
/// assemblies so a noisy peer cannot grow memory without bound.
struct MediaFrameChunkAssembler {
    private struct Assembly {
        var chunkCount: Int
        var totalBytes: Int
        var chunks: [Data?]
    }

    private let maxAssemblies = 8
    private let maxTotalBytes = MediaFrameV2Codec.defaultMaxPayloadBytes + 4096
    private var assemblies: [String: Assembly] = [:]
    private var insertionOrder: [String] = []

    mutating func accept(
        chunk: HermesRealtimeRelayMediaFrameChunk?,
        bytes: Data
    ) -> Data? {
        guard let chunk else { return bytes }
        guard chunk.chunkCount > 0,
              chunk.chunkIndex >= 0,
              chunk.chunkIndex < chunk.chunkCount,
              chunk.totalBytes > 0,
              chunk.totalBytes <= maxTotalBytes else {
            assemblies.removeValue(forKey: chunk.chunkId)
            insertionOrder.removeAll { $0 == chunk.chunkId }
            return nil
        }

        if assemblies[chunk.chunkId] == nil {
            trimOldestIfNeeded()
            assemblies[chunk.chunkId] = Assembly(
                chunkCount: chunk.chunkCount,
                totalBytes: chunk.totalBytes,
                chunks: Array(repeating: nil, count: chunk.chunkCount)
            )
            insertionOrder.append(chunk.chunkId)
        }

        guard var assembly = assemblies[chunk.chunkId],
              assembly.chunkCount == chunk.chunkCount,
              assembly.totalBytes == chunk.totalBytes else {
            assemblies.removeValue(forKey: chunk.chunkId)
            insertionOrder.removeAll { $0 == chunk.chunkId }
            return nil
        }

        assembly.chunks[chunk.chunkIndex] = bytes
        assemblies[chunk.chunkId] = assembly
        guard assembly.chunks.allSatisfy({ $0 != nil }) else { return nil }

        let complete = assembly.chunks.reduce(into: Data(capacity: assembly.totalBytes)) { result, part in
            result.append(part ?? Data())
        }
        assemblies.removeValue(forKey: chunk.chunkId)
        insertionOrder.removeAll { $0 == chunk.chunkId }
        return complete.count == assembly.totalBytes ? complete : nil
    }

    private mutating func trimOldestIfNeeded() {
        guard assemblies.count >= maxAssemblies, let oldest = insertionOrder.first else { return }
        insertionOrder.removeFirst()
        assemblies.removeValue(forKey: oldest)
    }
}
