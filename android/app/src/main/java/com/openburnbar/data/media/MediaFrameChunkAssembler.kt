package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayMediaFrameChunk
import java.io.ByteArrayOutputStream

// Reassembled frames may exceed the codec's max payload by the envelope
// (header/AEAD) overhead, so the byte budget gets a small fixed headroom.
private const val FRAME_ENVELOPE_HEADROOM_BYTES = 4096

internal class MediaFrameChunkAssembler(
    private val maxAssemblies: Int = 8,
    private val maxTotalBytes: Int = MediaFrameV2Codec.DEFAULT_MAX_PAYLOAD_BYTES + FRAME_ENVELOPE_HEADROOM_BYTES,
) {
    private data class Assembly(
        val chunkCount: Int,
        val totalBytes: Int,
        val chunks: Array<ByteArray?>,
    )

    private val assemblies = LinkedHashMap<String, Assembly>()

    fun accept(chunk: HermesRealtimeRelayMediaFrameChunk?, bytes: ByteArray): ByteArray? {
        if (chunk == null) return bytes
        val chunkValid =
            chunk.chunkCount > 0 &&
                chunk.chunkIndex in 0 until chunk.chunkCount &&
                chunk.totalBytes > 0 &&
                chunk.totalBytes <= maxTotalBytes
        if (!chunkValid) {
            assemblies.remove(chunk.chunkId)
            return null
        }

        val assembly =
            assemblies.getOrPut(chunk.chunkId) {
                trimOldestIfNeeded()
                Assembly(
                    chunkCount = chunk.chunkCount,
                    totalBytes = chunk.totalBytes,
                    chunks = arrayOfNulls(chunk.chunkCount),
                )
            }
        if (assembly.chunkCount != chunk.chunkCount || assembly.totalBytes != chunk.totalBytes) {
            assemblies.remove(chunk.chunkId)
            return null
        }

        assembly.chunks[chunk.chunkIndex] = bytes
        return finalizeAssembly(chunk.chunkId, assembly)
    }

    private fun finalizeAssembly(chunkId: String, assembly: Assembly): ByteArray? {
        if (assembly.chunks.any { it == null }) return null
        val output = ByteArrayOutputStream(assembly.totalBytes)
        for (part in assembly.chunks) {
            val chunk = part ?: return null
            output.write(chunk)
        }
        val assembled = output.toByteArray()
        assemblies.remove(chunkId)
        return assembled.takeIf { it.size == assembly.totalBytes }
    }

    private fun trimOldestIfNeeded() {
        if (assemblies.size < maxAssemblies) return
        val oldest = assemblies.keys.firstOrNull() ?: return
        assemblies.remove(oldest)
    }
}
