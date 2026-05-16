package com.openburnbar.data.media

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Android-side mic capture for Phase 5 (1:1 audio call). 1:1 port of
 * `MicrophoneCaptureService.swift` (iOS). Uses `AudioRecord` for raw
 * PCM @ 48 kHz mono and applies the platform `AcousticEchoCanceler` +
 * `NoiseSuppressor` audio effects when available — Android equivalent
 * of iOS Voice-Processing IO.
 *
 * Each captured PCM frame is handed to `onPcmFrame` for the Opus
 * encoder. The AEC + NS effects bind to the AudioRecord audio session
 * and run in-flight; consumers don't see them in the public API.
 */
class MicrophoneCaptureService(
    private val context: Context,
    private val onPcmFrame: suspend (ByteArray) -> Unit,
    private val sampleRateHz: Int = 48_000,
    private val frameDurationMs: Int = 20,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    sealed class Failure(message: String) : RuntimeException(message) {
        object PermissionDenied : Failure("OpenBurnBar needs microphone access. Open Settings → BurnBar to allow.")
        data class StartupFailed(val detail: String) : Failure("AudioRecord start failed: $detail")
        object NoSession : Failure("AudioRecord initialization failed: no audio session.")
    }

    sealed class Phase {
        object Idle : Phase()
        object Running : Phase()
        object Stopped : Phase()
        data class Failed(val reason: String) : Phase()
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    private var record: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var captureJob: Job? = null

    @SuppressLint("MissingPermission") // we check above
    fun start() {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            _phase.value = Phase.Failed(Failure.PermissionDenied.message ?: "")
            throw Failure.PermissionDenied
        }

        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val frameSamples = sampleRateHz * frameDurationMs / 1000
        val frameBytes = frameSamples * 2 // 16-bit mono
        val minBuffer = AudioRecord.getMinBufferSize(sampleRateHz, channelConfig, encoding)
        val bufferSize = maxOf(minBuffer, frameBytes * 4)

        val newRecord = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                sampleRateHz,
                channelConfig,
                encoding,
                bufferSize,
            )
        } catch (t: Throwable) {
            _phase.value = Phase.Failed(t.message ?: t.javaClass.simpleName)
            throw Failure.StartupFailed(t.message ?: t.javaClass.simpleName)
        }

        if (newRecord.state != AudioRecord.STATE_INITIALIZED) {
            newRecord.release()
            _phase.value = Phase.Failed("uninitialized")
            throw Failure.NoSession
        }

        // Bind AEC + NS audio effects when supported. Both are no-ops
        // on devices that lack hardware support — we mirror iOS by
        // never failing capture if the post-processing isn't available.
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(newRecord.audioSessionId)?.apply { enabled = true }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(newRecord.audioSessionId)?.apply { enabled = true }
        }

        try {
            newRecord.startRecording()
        } catch (t: Throwable) {
            newRecord.release()
            _phase.value = Phase.Failed(t.message ?: t.javaClass.simpleName)
            throw Failure.StartupFailed(t.message ?: t.javaClass.simpleName)
        }

        record = newRecord
        _phase.value = Phase.Running

        captureJob = scope.launch {
            val buffer = ByteArray(frameBytes)
            while (isActive && record === newRecord) {
                val read = newRecord.read(buffer, 0, frameBytes)
                if (read > 0) {
                    val frame = if (read == frameBytes) buffer.copyOf() else buffer.copyOf(read)
                    onPcmFrame(frame)
                }
            }
        }
    }

    fun stop() {
        captureJob?.cancel()
        captureJob = null
        val r = record
        record = null
        try {
            r?.stop()
        } catch (_: Throwable) {}
        r?.release()
        aec?.release(); aec = null
        ns?.release(); ns = null
        _phase.value = Phase.Stopped
    }

    fun shutdown() {
        stop()
        scope.cancel()
    }

    @Suppress("unused")
    val pcmFrameByteCount: Int get() = sampleRateHz * frameDurationMs / 1000 * 2
}
