package com.openburnbar.data.media

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.guava.await
import java.util.concurrent.Executors

/**
 * Android front-camera capture for Phase 5 (1:1 video calls). 1:1 port
 * of `CameraCaptureService.swift` (iOS). Uses CameraX's `Preview` use
 * case with a `SurfaceProvider` bound to the input surface of the
 * HEVC `MediaCodec` encoder so YUV → HEVC happens on the GPU.
 */
class CameraCaptureService(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
) {
    sealed class Failure(message: String) : RuntimeException(message) {
        object PermissionDenied : Failure("OpenBurnBar needs camera access. Open Settings → BurnBar to allow.")
        data class ConfigurationFailed(val detail: String) : Failure("Camera configuration failed: $detail")
        object NoCameraDevice : Failure("No front camera available on this device.")
    }

    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null

    /** Bind a CameraX `Preview` use case onto the supplied encoder input surface. */
    suspend fun start(encoderInputSurface: Surface) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) throw Failure.PermissionDenied

        val provider = awaitCameraProvider()
        cameraProvider = provider

        val preview = Preview.Builder().build().also { useCase ->
            useCase.setSurfaceProvider(backgroundExecutor) { request ->
                try {
                    request.provideSurface(encoderInputSurface, mainExecutor) { /* result */ }
                } catch (_: Throwable) {
                    // Surface unavailable — ignore; pipeline will retry on next bind.
                }
            }
        }
        val selector = CameraSelector.DEFAULT_FRONT_CAMERA

        try {
            provider.unbindAll()
            provider.bindToLifecycle(lifecycleOwner, selector, preview)
        } catch (t: Throwable) {
            throw Failure.ConfigurationFailed(t.message ?: t.javaClass.simpleName)
        }
    }

    fun stop() {
        cameraProvider?.unbindAll()
        cameraProvider = null
    }

    fun shutdown() {
        stop()
        backgroundExecutor.shutdown()
    }

    private suspend fun awaitCameraProvider(): ProcessCameraProvider =
        ProcessCameraProvider.getInstance(context).await()
}
