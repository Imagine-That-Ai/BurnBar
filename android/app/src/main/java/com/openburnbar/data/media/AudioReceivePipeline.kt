package com.openburnbar.data.media

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Android-side Opus → PCM decode + playback path. 1:1 port of
 * `AudioReceivePipeline.swift` (iOS). Adaptive jitter buffer (60 ms /
 * 3 packets target). Dropped packets are concealed via Opus PLC
 * inside the decoder.
 */
class AudioReceivePipeline(
    private val sampleRateHz: Int = 48_000,
    private val frameDurationMs: Int = 20,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    sealed class Phase {
        object Idle : Phase()
        object Running : Phase()
        object Stopped : Phase()
        data class Failed(val reason: String) : Phase()
    }

    private val mutex = Mutex()
    private val jitterBuffer = JitterBuffer()
    private var audioTrack: AudioTrack? = null
    private var decoder: OpusCodec.Decoder? = null
    private var renderJob: Job? = null

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    fun start() {
        scope.launch {
            mutex.withLock {
                if (!OpusCodec.isAvailable()) {
                    _phase.value = Phase.Failed("opus codec unavailable on this build")
                    return@withLock
                }
                val channelConfig = AudioFormat.CHANNEL_OUT_MONO
                val encoding = AudioFormat.ENCODING_PCM_16BIT
                val frameSamples = sampleRateHz * frameDurationMs / 1000
                val frameBytes = frameSamples * 2
                val minBuffer = AudioTrack.getMinBufferSize(sampleRateHz, channelConfig, encoding)
                val bufferSize = maxOf(minBuffer, frameBytes * 6)

                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sampleRateHz)
                            .setEncoding(encoding)
                            .setChannelMask(channelConfig)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                track.play()
                audioTrack = track
                decoder = OpusCodec.decoder(sampleRateHz = sampleRateHz, channels = 1)
                _phase.value = Phase.Running
                renderJob = scope.launch { renderLoop() }
            }
        }
    }

    suspend fun ingest(frame: MediaFrame) {
        if (frame.kind != MediaFrame.Kind.AUDIO_OPUS) return
        if (MediaFrame.Flags.MUTED in frame.flags) {
            // Mute marker: keep clock alignment by skipping decode; AudioTrack stream paces itself.
            return
        }
        mutex.withLock { jitterBuffer.push(frame) }
    }

    private suspend fun renderLoop() {
        val track = audioTrack ?: return
        val decoder = decoder ?: return
        while (scope.isActive) {
            val popped = mutex.withLock { jitterBuffer.popNext() }
            if (popped == null) {
                delay(frameDurationMs.toLong())
                continue
            }
            try {
                val pcm = decoder.decode(popped.payload)
                track.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
            } catch (_: Throwable) {
                // Concealment: skip this frame; Opus PLC inside the decoder handles silence.
            }
        }
    }

    fun stop() {
        scope.launch {
            mutex.withLock {
                renderJob?.cancel()
                renderJob = null
                jitterBuffer.clear()
                runCatching { audioTrack?.pause(); audioTrack?.flush(); audioTrack?.release() }
                audioTrack = null
                runCatching { decoder?.close() }
                decoder = null
                _phase.value = Phase.Stopped
            }
        }
    }

    @Suppress("unused")
    val activeBufferSize: Int get() = jitterBuffer.size

    @Suppress("unused")
    val streamType: Int = AudioManager.STREAM_VOICE_CALL
}
