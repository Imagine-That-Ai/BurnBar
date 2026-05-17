package com.openburnbar.irohrelay

import java.lang.reflect.InvocationTargetException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Reflection-backed wrapper around `uniffi.openburnbar_iroh.IrohBlobNode`.
 * Same shape as `OpenBurnBarIrohFfiBackend` but pinned to iroh-blobs.
 */
class OpenBurnBarIrohBlobFfiBackend(
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : IrohBlobBackend {
    private var node: Any? = null

    override suspend fun bootstrap(
        secret: ByteArray,
        storeDirectoryPath: String,
        relayURL: String?,
    ): IrohEndpointIdentity = withContext(dispatcher) {
        val instance = reflected("IrohBlobNode.constructor") {
            blobNodeClass()
                .getDeclaredConstructor()
                .newInstance()
        } ?: error("IrohBlobNode constructor returned null")
        node = instance
        val secretMaterial = run {
            val cls = secretKeyMaterialClass()
            val ctor = cls.constructors.first { it.parameterTypes.size == 1 }
            ctor.newInstance(secret)
        }
        val identity = reflected("IrohBlobNode.bootstrap") {
            blobNodeClass()
                .getMethod("bootstrap", secretKeyMaterialClass(), String::class.java, String::class.java)
                .invoke(instance, secretMaterial, storeDirectoryPath, relayURL.orEmpty())
        } ?: throw IrohBlobBackendError.NotInitialized
        mapIdentity(identity)
    }

    override suspend fun publishBlob(localPath: String): String = withContext(dispatcher) {
        val instance = node ?: throw IrohBlobBackendError.NotInitialized
        val ticket = try {
            reflected("IrohBlobNode.publishBlob") {
                blobNodeClass()
                    .getMethod("publishBlob", String::class.java)
                    .invoke(instance, localPath)
            } ?: throw IrohBlobBackendError.PublishFailed("publishBlob returned null")
        } catch (err: IrohBackendError.RuntimeFailed) {
            throw IrohBlobBackendError.PublishFailed(err.detail)
        }
        // BlobTicketBytes is a uniffi record with a `text` field.
        ticket.javaClass.getMethod("getText").invoke(ticket) as String
    }

    override suspend fun fetchBlob(ticketText: String, destination: String): BlobTransferStats =
        withContext(dispatcher) {
            val instance = node ?: throw IrohBlobBackendError.NotInitialized
            val stats = try {
                reflected("IrohBlobNode.fetchBlob") {
                    blobNodeClass()
                        .getMethod("fetchBlob", String::class.java, String::class.java)
                        .invoke(instance, ticketText, destination)
                } ?: throw IrohBlobBackendError.FetchFailed("fetchBlob returned null")
            } catch (err: IrohBackendError.RuntimeFailed) {
                throw IrohBlobBackendError.FetchFailed(err.detail)
            }
            val cls = stats.javaClass
            BlobTransferStats(
                bytesTotal = (cls.getMethod("getBytesTotal").invoke(stats) as Long),
                blake3Hash = cls.getMethod("getBlake3Hash").invoke(stats) as String,
                durationMillis = (cls.getMethod("getDurationMillis").invoke(stats) as Long),
                didResume = cls.getMethod("getDidResume").invoke(stats) as Boolean,
            )
        }

    override suspend fun identity(): IrohEndpointIdentity = withContext(dispatcher) {
        val instance = node ?: throw IrohBlobBackendError.NotInitialized
        val identity = reflected("IrohBlobNode.identity") {
            blobNodeClass().getMethod("identity").invoke(instance)
        }
            ?: throw IrohBlobBackendError.NotInitialized
        mapIdentity(identity)
    }

    override suspend fun shutdown() = withContext(dispatcher) {
        val instance = node ?: return@withContext
        try {
            reflected("IrohBlobNode.shutdown") {
                blobNodeClass().getMethod("shutdown").invoke(instance)
            }
        } catch (_: Throwable) {
            // best-effort.
        }
        node = null
    }

    private fun mapIdentity(generated: Any): IrohEndpointIdentity {
        val cls = generated.javaClass
        val rawPublicKey = cls.getMethod("getRawPublicKey").invoke(generated) as ByteArray
        val nodeId = cls.getMethod("getNodeId").invoke(generated) as String
        val relayURL = cls.getMethod("getRelayUrl").invoke(generated) as String
        @Suppress("UNCHECKED_CAST")
        val directAddresses = cls.getMethod("getDirectAddresses").invoke(generated) as List<String>
        return IrohEndpointIdentity(
            nodeId = nodeId,
            rawPublicKey = rawPublicKey,
            relayURL = relayURL.ifEmpty { null },
            directAddresses = directAddresses,
        )
    }

    private inline fun <T> reflected(operation: String, block: () -> T): T {
        try {
            return block()
        } catch (err: InvocationTargetException) {
            val cause = err.targetException ?: err.cause ?: err
            throw IrohBackendError.RuntimeFailed("$operation failed: ${cause.javaClass.name}: ${cause.message ?: "no message"}")
        }
    }

    companion object {
        @Volatile private var cachedAvailability: Boolean? = null
        fun isAvailable(): Boolean {
            cachedAvailability?.let { return it }
            val ok = try { blobNodeClass(); true } catch (_: Throwable) { false }
            cachedAvailability = ok
            return ok
        }

        private fun blobNodeClass(): Class<*> = Class.forName("uniffi.openburnbar_iroh.IrohBlobNode")
        private fun secretKeyMaterialClass(): Class<*> =
            Class.forName("uniffi.openburnbar_iroh.IrohSecretKeyMaterial")
    }
}
