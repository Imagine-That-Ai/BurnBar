package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayMediaFrameChunk
import java.io.ByteArrayOutputStream

private const val MEDIA_FRAME_CHUNK_VAL_4096 = 4096

internal class MediaFrameChunkAssembler(
    private val maxAssemblies: Int = 8,
    private val maxTotalBytes: Int = MediaFrameV2Codec.DEFAULT_MAX_PAYLOAD_BYTES + MEDIA_FRAME_CHUNK_VAL_4096,
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
            output.write(part!!)
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
