package com.openburnbar.irohrelay

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal val javaPrimitiveInt: Class<*> = Int::class.javaPrimitiveType!!

internal fun Class<*>.irohGeneratedMethod(
    baseName: String,
    vararg parameterTypes: Class<*>,
): Method {
    return methods.firstOrNull { method ->
        (method.name == baseName || method.name.startsWith("$baseName-")) &&
            method.parameterTypes.contentEquals(parameterTypes)
    } ?: getMethod(baseName, *parameterTypes)
}

/**
 * Bridge between Kotlin and the UniFFI-generated `uniffi.openburnbar_iroh`
 * package. Resolved via reflection so this module compiles cleanly with
 * or without `Vendor/openburnbar-iroh.aar` on the classpath — the AAR
 * lands from `scripts/build-iroh-android-aar.sh` / the CI workflow and
 * exposes `IrohEndpointHandle`, `IrohStream`, `IrohSecretKeyMaterial`,
 * `IrohNodeIdentity`, `IrohDatagramChannel`, and helpers under
 * `uniffi.openburnbar_iroh.*`.
 *
 * `OpenBurnBarIrohFfiBackend.isAvailable()` returns true when the
 * bindings are loadable. Callers should `if (OpenBurnBarIrohFfiBackend.isAvailable())`
 * before wiring the JNI transport into a composite — otherwise the
 * loopback / Firestore fallback is used.
 */
class OpenBurnBarIrohFfiBackend(
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : IrohEndpointBackend {
    private var handleObject: Any? = null

    override suspend fun bootstrap(secret: ByteArray, relayURL: String?): IrohEndpointIdentity =
        withContext(dispatcher) {
            val instance = reflected("IrohEndpointHandle.constructor") {
                handleClass()
                    .getDeclaredConstructor()
                    .newInstance()
            } ?: error("IrohEndpointHandle constructor returned null")
            handleObject = instance
            val secretMaterial = secretKeyMaterialFromRaw(secret)
            val identity = reflected("IrohEndpointHandle.bootstrap") {
                handleClass()
                    .getMethod("bootstrap", secretKeyMaterialClass(), String::class.java)
                    .invoke(instance, secretMaterial, relayURL.orEmpty())
            } ?: error("bootstrap returned null")
            mapIdentity(identity)
        }

    override suspend fun identity(): IrohEndpointIdentity = withContext(dispatcher) {
        val instance = handleObject ?: throw IrohBackendError.NotInitialized
        val identity = reflected("IrohEndpointHandle.identity") {
            handleClass().getMethod("identity").invoke(instance)
        }
            ?: throw IrohBackendError.NotInitialized
        mapIdentity(identity)
    }

    override suspend fun connect(target: IrohDialTarget, timeoutMillis: Long): IrohBackendStream =
        withContext(dispatcher) {
            val instance = handleObject ?: throw IrohBackendError.NotInitialized
            val timeoutSeconds = ((timeoutMillis + 999) / 1000).coerceAtLeast(1).toInt()
            val stream = try {
                reflected("IrohEndpointHandle.connect") {
                    handleClass().irohGeneratedMethod(
                        "connect",
                        String::class.java, String::class.java, List::class.java, javaPrimitiveInt,
                    ).invoke(instance, target.nodeId, target.relayURL.orEmpty(), target.directAddresses, timeoutSeconds)
                } ?: throw IrohBackendError.ConnectFailed("uniffi connect returned null")
            } catch (err: IrohBackendError.RuntimeFailed) {
                throw IrohBackendError.ConnectFailed(err.detail)
            }
            UniffiBackendStream(stream)
        }

    override suspend fun acceptOne(timeoutMillis: Long): IrohBackendStream = withContext(dispatcher) {
        val instance = handleObject ?: throw IrohBackendError.NotInitialized
        val timeoutSeconds = ((timeoutMillis + 999) / 1000).coerceAtLeast(1).toInt()
        val stream = try {
            reflected("IrohEndpointHandle.acceptOne") {
                handleClass().irohGeneratedMethod("acceptOne", javaPrimitiveInt)
                    .invoke(instance, timeoutSeconds)
            } ?: throw IrohBackendError.AcceptFailed("uniffi accept returned null")
        } catch (err: IrohBackendError.RuntimeFailed) {
            throw IrohBackendError.AcceptFailed(err.detail)
        }
        UniffiBackendStream(stream)
    }

    override suspend fun shutdown() = withContext(dispatcher) {
        val instance = handleObject ?: return@withContext
        try {
            reflected("IrohEndpointHandle.shutdown") {
                handleClass().getMethod("shutdown").invoke(instance)
            }
        } catch (_: Throwable) {
            // best-effort shutdown — bindings throw on double-close; ignore.
        }
        handleObject = null
    }

    /** Open a datagram channel against a remote peer. Used by Mercury audio. */
    suspend fun openDatagramChannel(
        target: IrohDialTarget,
        timeoutMillis: Long,
    ): Any = withContext(dispatcher) {
        val instance = handleObject ?: throw IrohBackendError.NotInitialized
        val timeoutSeconds = ((timeoutMillis + 999) / 1000).coerceAtLeast(1).toInt()
        try {
            reflected("IrohEndpointHandle.openDatagramChannel") {
                handleClass().irohGeneratedMethod(
                    "openDatagramChannel",
                    String::class.java, String::class.java, List::class.java, javaPrimitiveInt,
                ).invoke(instance, target.nodeId, target.relayURL.orEmpty(), target.directAddresses, timeoutSeconds)
            } ?: throw IrohBackendError.ConnectFailed("uniffi openDatagramChannel returned null")
        } catch (err: IrohBackendError.RuntimeFailed) {
            throw IrohBackendError.ConnectFailed(err.detail)
        }
    }

    suspend fun acceptDatagramChannel(timeoutMillis: Long): Any = withContext(dispatcher) {
        val instance = handleObject ?: throw IrohBackendError.NotInitialized
        val timeoutSeconds = ((timeoutMillis + 999) / 1000).coerceAtLeast(1).toInt()
        try {
            reflected("IrohEndpointHandle.acceptDatagramChannel") {
                handleClass().irohGeneratedMethod("acceptDatagramChannel", javaPrimitiveInt)
                    .invoke(instance, timeoutSeconds)
            } ?: throw IrohBackendError.AcceptFailed("uniffi acceptDatagramChannel returned null")
        } catch (err: IrohBackendError.RuntimeFailed) {
            throw IrohBackendError.AcceptFailed(err.detail)
        }
    }

    private inner class UniffiBackendStream(private val streamObject: Any) : IrohBackendStream {
        override suspend fun sendFrame(envelope: ByteArray) = withContext(dispatcher) {
            try {
                reflected("IrohStream.sendFrame") {
                    streamClass().getMethod("sendFrame", ByteArray::class.java).invoke(streamObject, envelope)
                }
            } catch (t: Throwable) {
                throw IrohBackendError.StreamFailed(t.message ?: t.javaClass.simpleName)
            }
            Unit
        }

        override suspend fun recvFrame(): ByteArray? = withContext(dispatcher) {
            try {
                reflected("IrohStream.recvFrame") {
                    streamClass().getMethod("recvFrame").invoke(streamObject) as ByteArray?
                }
            } catch (t: Throwable) {
                throw IrohBackendError.StreamFailed(t.message ?: t.javaClass.simpleName)
            }
        }

        override suspend fun close() = withContext(dispatcher) {
            try {
                reflected("IrohStream.closeStream") {
                    streamClass().getMethod("closeStream").invoke(streamObject)
                }
            } catch (_: Throwable) {
                // idempotent close.
            }
            Unit
        }
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

    private fun secretKeyMaterialFromRaw(raw: ByteArray): Any {
        val cls = secretKeyMaterialClass()
        // Generated record exposes a constructor taking ByteArray.
        val ctor = cls.constructors.first { it.parameterTypes.size == 1 }
        return ctor.newInstance(raw)
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
        /**
         * Probe the classpath for the UniFFI-generated bindings. Returns
         * true only when `uniffi.openburnbar_iroh.IrohEndpointHandle` and
         * the companion shared object load successfully.
         */
        @Volatile private var cachedAvailability: Boolean? = null
        fun isAvailable(): Boolean {
            cachedAvailability?.let { return it }
            val ok = try {
                handleClass()
                true
            } catch (_: Throwable) {
                false
            }
            cachedAvailability = ok
            return ok
        }

        private fun handleClass(): Class<*> =
            Class.forName("uniffi.openburnbar_iroh.IrohEndpointHandle")

        private fun streamClass(): Class<*> =
            Class.forName("uniffi.openburnbar_iroh.IrohStream")

        private fun secretKeyMaterialClass(): Class<*> =
            Class.forName("uniffi.openburnbar_iroh.IrohSecretKeyMaterial")
    }
}
