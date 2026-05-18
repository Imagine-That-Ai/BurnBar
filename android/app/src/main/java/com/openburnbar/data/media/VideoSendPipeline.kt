package com.openburnbar.data.media

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.PowerManager
import android.view.Surface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.nio.ByteBuffer

/**
 * Android-side video send pipeline for Phase 5 calls. 1:1 port of the
 * iOS `VideoEncoder` + Mac `VideoEncoder` substrate. HEVC `MediaCodec`
 * (with H.264 fallback) in surface-input mode so CameraX can render
 * directly into the encoder.
 *
 * Thermal listener (`PowerManager.OnThermalStatusChangedListener` on
 * API 29+) drives bitrate halving / call-termination parity with the
 * iOS `BitrateController` → `MediaSessionCoordinator` linkage.
 */
class VideoSendPipeline(
    private val context: Context,
    private val width: Int = 720,
    private val height: Int = 1280,
    private val initialBitrate: Int = 1_200_000,
    private val frameRate: Int = 30,
    private val keyframeIntervalSec: Int = 2,
    private val onEncoded: suspend (MediaFrame) -> Unit,
    private val onCallTermination: () -> Unit = {},
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    sealed class Phase {
        object Idle : Phase()
        data class Running(val codec: Codec) : Phase()
        object Stopped : Phase()
        data class Failed(val reason: String) : Phase()
    }

    enum class Codec(val mime: String) {
        HEVC(MediaFormat.MIMETYPE_VIDEO_HEVC),
        H264(MediaFormat.MIMETYPE_VIDEO_AVC),
    }

    private val mutex = Mutex()
    private var encoder: MediaCodec? = null
    private var resolvedCodec: Codec = Codec.HEVC
    private var inputSurface: Surface? = null
    private var drainJob: Job? = null
    private var currentGopID: UInt = 0u
    private var currentFrameIndex: UInt = 0u

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    /** Set up the encoder and return the input surface the camera should draw into. */
    suspend fun start(): Surface = mutex.withLock {
        if (inputSurface != null) return@withLock inputSurface!!
        val target = pickCodec()
        val format = MediaFormat.createVideoFormat(target.mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, initialBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeIntervalSec)
        }
        val codec = try {
            MediaCodec.createEncoderByType(target.mime).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
        } catch (t: Throwable) {
            if (target == Codec.HEVC) {
                // Fallback to H.264.
                val fallback = MediaCodec.createEncoderByType(Codec.H264.mime).apply {
                    configure(
                        MediaFormat.createVideoFormat(Codec.H264.mime, width, height).apply {
                            setInteger(
                                MediaFormat.KEY_COLOR_FORMAT,
                                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                            )
                            setInteger(MediaFormat.KEY_BIT_RATE, initialBitrate)
                            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeIntervalSec)
                        },
                        null,
                        null,
                        MediaCodec.CONFIGURE_FLAG_ENCODE,
                    )
                }
                resolvedCodec = Codec.H264
                fallback
            } else {
                _phase.value = Phase.Failed(t.message ?: t.javaClass.simpleName)
                throw t
            }
        } ?: run {
            _phase.value = Phase.Failed("encoder creation returned null")
            throw IllegalStateException("encoder creation returned null")
        }
        if (target != Codec.HEVC) resolvedCodec = Codec.H264 else resolvedCodec = target
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        inputSurface = surface
        _phase.value = Phase.Running(resolvedCodec)
        drainJob = scope.launch { drainLoop(codec) }
        startThermalMonitorIfAvailable()
        surface
    }

    suspend fun stop() = mutex.withLock {
        drainJob?.cancel()
        drainJob = null
        try { encoder?.stop() } catch (_: Throwable) {}
        try { encoder?.release() } catch (_: Throwable) {}
        try { inputSurface?.release() } catch (_: Throwable) {}
        encoder = null
        inputSurface = null
        _phase.value = Phase.Stopped
    }

    /** Adjust encoder bitrate at runtime — wired to `BweEstimator` feedback. */
    suspend fun setBitrate(bps: Int) = mutex.withLock {
        val codec = encoder ?: return@withLock
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            val params = android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bps)
            }
            try { codec.setParameters(params) } catch (_: Throwable) {}
        }
    }

    /** Force a keyframe on the next encoded frame — used in response to a `KeyframeRequest`. */
    suspend fun requestKeyframe() = mutex.withLock {
        val codec = encoder ?: return@withLock
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val params = android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            try { codec.setParameters(params) } catch (_: Throwable) {}
        }
    }

    private suspend fun drainLoop(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (true) {
                val outIndex = codec.dequeueOutputBuffer(info, 20_000)
                when {
                    outIndex >= 0 -> {
                        val out: ByteBuffer = codec.getOutputBuffer(outIndex) ?: continue
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        val payload = ByteArray(info.size).also { out.get(it) }
                        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        val flags = if (isKey) MediaFrame.Flags.KEYFRAME else MediaFrame.Flags.NONE
                        val (gop, idx) = nextFrameIndices(isKeyframe = isKey)
                        val frame = MediaFrame(
                            kind = MediaFrame.Kind.VIDEO_NAL,
                            flags = flags,
                            gopID = gop,
                            frameIndex = idx,
                            presentationTimestampMillis = (info.presentationTimeUs / 1000).toULong(),
                            payload = payload,
                        )
                        onEncoded(frame)
                        codec.releaseOutputBuffer(outIndex, false)
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { /* format change OK */ }
                    else -> { /* INFO_TRY_AGAIN_LATER — keep looping */ }
                }
            }
        } catch (_: IllegalStateException) {
            // codec stopped; exit gracefully.
        }
    }

    private fun nextFrameIndices(isKeyframe: Boolean): Pair<UInt, UInt> {
        if (isKeyframe) {
            currentGopID = currentGopID + 1u
            currentFrameIndex = 0u
        } else {
            currentFrameIndex = currentFrameIndex + 1u
        }
        return currentGopID to currentFrameIndex
    }

    private fun pickCodec(): Codec {
        return runCatching {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val format = MediaFormat.createVideoFormat(Codec.HEVC.mime, width, height)
            if (list.findEncoderForFormat(format) != null) Codec.HEVC else Codec.H264
        }.getOrDefault(Codec.HEVC)
    }

    private fun startThermalMonitorIfAvailable() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            scope.launch {
                when {
                    status >= PowerManager.THERMAL_STATUS_CRITICAL -> {
                        // Plan parity: terminate the call at critical thermal pressure.
                        try { stop() } catch (_: Throwable) {}
                        onCallTermination()
                    }
                    status >= PowerManager.THERMAL_STATUS_SEVERE -> setBitrate(initialBitrate / 2)
                    status >= PowerManager.THERMAL_STATUS_MODERATE -> setBitrate((initialBitrate * 2) / 3)
                    else -> setBitrate(initialBitrate)
                }
            }
        }
        try {
            power.addThermalStatusListener(listener)
        } catch (_: Throwable) {
            // Listener not supported — fall back to silent operation.
        }
    }
}
