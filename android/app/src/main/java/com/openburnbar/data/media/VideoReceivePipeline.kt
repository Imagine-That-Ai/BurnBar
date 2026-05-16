package com.openburnbar.data.media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
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
 * Android-side decode pipeline for inbound Mercury video frames. 1:1 port
 * of `VideoReceivePipeline.swift`.
 *
 * Phase 3 (Mac screen share, HEVC) and Phase 5 (Mac webcam, HEVC). Reads
 * `MediaFrame`s, decodes via `MediaCodec` async API, and renders onto
 * the receiver-provided `Surface`. Falls back to H.264 if HEVC not
 * available.
 *
 * GOP discard: when a non-keyframe arrives whose `gopID` doesn't match
 * the current GOP and we never received the keyframe, drop frames until
 * the next keyframe (signaled via `MediaFrame.Flags.KEYFRAME`). Stalled
 * GOPs trigger a keyframe-request callback so the caller can emit a
 * `media.control` `KeyframeRequest` frame back to the sender.
 */
class VideoReceivePipeline(
    private val codec: Codec = Codec.HEVC,
    private val onKeyframeRequest: () -> Unit = {},
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    enum class Codec(val mime: String) {
        HEVC(MediaFormat.MIMETYPE_VIDEO_HEVC),
        H264(MediaFormat.MIMETYPE_VIDEO_AVC),
    }

    sealed class Phase {
        object Idle : Phase()
        data class Running(val codec: Codec) : Phase()
        data class Failed(val reason: String) : Phase()
        object Stopped : Phase()
    }

    private val mutex = Mutex()
    private var decoder: MediaCodec? = null
    private var resolvedCodec: Codec = codec
    private var currentGopID: UInt = UInt.MAX_VALUE
    private var renderJob: Job? = null

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    private val _stats = MutableStateFlow(Stats())
    val stats: StateFlow<Stats> = _stats.asStateFlow()

    data class Stats(
        val widthPx: Int = 0,
        val heightPx: Int = 0,
        val codecName: String = "",
        val bitsPerSecond: Int = 0,
        val roundTripMillis: Int = 0,
    )

    suspend fun start(outputSurface: Surface, widthPx: Int = 1920, heightPx: Int = 1080) {
        mutex.withLock {
            stopLocked()
            val target = pickCodec(widthPx = widthPx, heightPx = heightPx)
            val format = MediaFormat.createVideoFormat(target.mime, widthPx, heightPx).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            }
            try {
                val newDecoder = MediaCodec.createDecoderByType(target.mime).apply {
                    configure(format, outputSurface, null, 0)
                    start()
                }
                decoder = newDecoder
                resolvedCodec = target
                _phase.value = Phase.Running(target)
                _stats.value = _stats.value.copy(
                    widthPx = widthPx,
                    heightPx = heightPx,
                    codecName = target.name,
                )
                renderJob = scope.launch { drainOutput(newDecoder) }
            } catch (t: Throwable) {
                if (target == Codec.HEVC) {
                    // Fallback to H.264.
                    val fallback = MediaCodec.createDecoderByType(Codec.H264.mime).apply {
                        configure(
                            MediaFormat.createVideoFormat(Codec.H264.mime, widthPx, heightPx).apply {
                                setInteger(
                                    MediaFormat.KEY_COLOR_FORMAT,
                                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                                )
                                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                            },
                            outputSurface,
                            null,
                            0,
                        )
                        start()
                    }
                    decoder = fallback
                    resolvedCodec = Codec.H264
                    _phase.value = Phase.Running(Codec.H264)
                    _stats.value = _stats.value.copy(codecName = Codec.H264.name)
                    renderJob = scope.launch { drainOutput(fallback) }
                } else {
                    _phase.value = Phase.Failed(t.message ?: t.javaClass.simpleName)
                    throw t
                }
            }
        }
    }

    suspend fun ingest(frame: MediaFrame) {
        if (frame.kind != MediaFrame.Kind.VIDEO_NAL) return
        val codec = mutex.withLock { decoder } ?: return

        val isKeyframe = MediaFrame.Flags.KEYFRAME in frame.flags
        if (!isKeyframe && frame.gopID != currentGopID) {
            // Stale frame for a GOP we don't have — request a fresh key.
            onKeyframeRequest()
            return
        }
        if (isKeyframe) currentGopID = frame.gopID

        val inputIndex = try {
            codec.dequeueInputBuffer(20_000)
        } catch (_: IllegalStateException) {
            return
        }
        if (inputIndex < 0) return
        val buffer: ByteBuffer = codec.getInputBuffer(inputIndex) ?: return
        buffer.clear()
        if (frame.payload.size > buffer.capacity()) return
        buffer.put(frame.payload)
        codec.queueInputBuffer(
            inputIndex,
            0,
            frame.payload.size,
            (frame.presentationTimestampMillis * 1_000uL).toLong(),
            if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
        )
    }

    suspend fun stop() {
        mutex.withLock { stopLocked() }
    }

    private fun stopLocked() {
        renderJob?.cancel()
        renderJob = null
        decoder?.runCatching {
            stop()
            release()
        }
        decoder = null
        currentGopID = UInt.MAX_VALUE
        _phase.value = Phase.Stopped
    }

    private suspend fun drainOutput(decoder: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (true) {
                val outIndex = decoder.dequeueOutputBuffer(info, 20_000)
                when {
                    outIndex >= 0 -> decoder.releaseOutputBuffer(outIndex, true)
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val format = decoder.outputFormat
                        val w = format.getInteger(MediaFormat.KEY_WIDTH)
                        val h = format.getInteger(MediaFormat.KEY_HEIGHT)
                        _stats.value = _stats.value.copy(widthPx = w, heightPx = h)
                    }
                    else -> { /* INFO_TRY_AGAIN_LATER or BUFFERS_CHANGED — keep draining. */ }
                }
            }
        } catch (_: IllegalStateException) {
            // Decoder torn down; exit drain loop.
        }
    }

    fun updateRoundTripStats(rttMillis: Int, bitsPerSecond: Int) {
        _stats.value = _stats.value.copy(
            roundTripMillis = rttMillis,
            bitsPerSecond = bitsPerSecond,
        )
    }

    private fun pickCodec(widthPx: Int, heightPx: Int): Codec {
        if (codec == Codec.H264) return Codec.H264
        return runCatching {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val format = MediaFormat.createVideoFormat(Codec.HEVC.mime, widthPx, heightPx)
            if (list.findDecoderForFormat(format) != null) Codec.HEVC else Codec.H264
        }.getOrDefault(Codec.HEVC)
    }
}
