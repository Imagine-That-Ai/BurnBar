package com.openburnbar.data.media

/**
 * Reflection-based bridge to the `libopus` JNI wrapper packed into the
 * `Vendor/opus-android.aar` artifact emitted by
 * `scripts/build_opus_android.sh`. iOS uses Apple's bundled Opus
 * decoder/encoder via AVAudioConverter; Android has no system Opus
 * codec, so we ship our own.
 *
 * Until the AAR is on the classpath the codec compiles but throws at
 * runtime — `OpusCodec.isAvailable()` lets callers feature-detect and
 * gate the call pipeline behind a polite "Opus codec unavailable on
 * this build" notice.
 *
 * Expected JNI surface (loaded via reflection so this module compiles
 * without the AAR):
 *
 * ```
 * package ai.openburnbar.opus;
 *
 * public final class OpusEncoder {
 *     public OpusEncoder(int sampleRate, int channels, int bitrate);
 *     public byte[] encode(byte[] pcm16);  // returns Opus packet
 *     public void close();
 * }
 *
 * public final class OpusDecoder {
 *     public OpusDecoder(int sampleRate, int channels);
 *     public byte[] decode(byte[] packet); // returns PCM16
 *     public void close();
 * }
 * ```
 */
object OpusCodec {

    @Volatile private var cachedAvailability: Boolean? = null

    fun isAvailable(): Boolean {
        cachedAvailability?.let { return it }
        val available = try {
            Class.forName(ENCODER_CLASS)
            Class.forName(DECODER_CLASS)
            true
        } catch (_: Throwable) {
            false
        }
        cachedAvailability = available
        return available
    }

    /** Throws `IllegalStateException` when the AAR is not on the classpath. */
    fun encoder(sampleRateHz: Int = 48_000, channels: Int = 1, bitrate: Int = 32_000): Encoder {
        val cls = loadClass(ENCODER_CLASS) ?: throw IllegalStateException("opus encoder unavailable")
        val ctor = cls.getConstructor(Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        val instance = ctor.newInstance(sampleRateHz, channels, bitrate)
        return Encoder(cls = cls, instance = instance)
    }

    fun decoder(sampleRateHz: Int = 48_000, channels: Int = 1): Decoder {
        val cls = loadClass(DECODER_CLASS) ?: throw IllegalStateException("opus decoder unavailable")
        val ctor = cls.getConstructor(Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        val instance = ctor.newInstance(sampleRateHz, channels)
        return Decoder(cls = cls, instance = instance)
    }

    private fun loadClass(name: String): Class<*>? = try { Class.forName(name) } catch (_: Throwable) { null }

    class Encoder internal constructor(private val cls: Class<*>, private val instance: Any) : AutoCloseable {
        fun encode(pcm: ByteArray): ByteArray {
            return cls.getMethod("encode", ByteArray::class.java)
                .invoke(instance, pcm) as ByteArray
        }

        override fun close() {
            runCatching { cls.getMethod("close").invoke(instance) }
        }
    }

    class Decoder internal constructor(private val cls: Class<*>, private val instance: Any) : AutoCloseable {
        fun decode(packet: ByteArray): ByteArray {
            return cls.getMethod("decode", ByteArray::class.java)
                .invoke(instance, packet) as ByteArray
        }

        override fun close() {
            runCatching { cls.getMethod("close").invoke(instance) }
        }
    }

    private const val ENCODER_CLASS = "ai.openburnbar.opus.OpusEncoder"
    private const val DECODER_CLASS = "ai.openburnbar.opus.OpusDecoder"
}
