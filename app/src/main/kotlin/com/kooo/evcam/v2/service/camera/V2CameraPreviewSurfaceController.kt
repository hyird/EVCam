package com.kooo.evcam.v2.service.camera

import android.os.Handler
import android.view.Surface
import com.kooo.evcam.v2.log.V2AppLog
import com.kooo.evcam.v2.nativebridge.V2NativeCompositor

internal class V2CameraPreviewSurfaceController(
    private val nativeCompositor: V2NativeCompositor,
    private val pipelineHandle: Long,
    private val slots: List<V2CameraSlot>,
    private val statusFormatter: V2CameraStatusFormatter,
    private val renderHandler: Handler,
    private val previewMaxFps: Int,
    private val cameraAccessAllowed: () -> Boolean,
    private val released: () -> Boolean,
    private val publishStatus: () -> Unit,
    private val publishStatusIfNeeded: () -> Unit,
) {
    private var previewRenderingEnabled = true
    private var compositePreviewAttached = false
    private var compositePreviewSurface: Surface? = null

    fun attachCompositePreviewSurface(surface: Surface) {
        if (released() || pipelineHandle == 0L) return
        if (!cameraAccessAllowed()) {
            V2AppLog.w(TAG, "attach composite preview skipped: screen is off")
            return
        }
        if (compositePreviewAttached && compositePreviewSurface === surface && surface.isValid) {
            V2AppLog.d(TAG, "attach composite preview skipped: same surface already attached")
            startPreviewWorkerIfNeeded()
            publishStatusIfNeeded()
            return
        }
        V2AppLog.d(TAG, "attach composite preview")
        if (!nativeCompositor.attachCompositePreview(surface)) {
            compositePreviewAttached = false
            compositePreviewSurface = null
            V2AppLog.e(TAG, "attach composite preview failed: ${nativeCompositor.lastError()}")
            startPreviewWorkerIfNeeded()
            publishStatus()
            return
        }
        compositePreviewAttached = true
        compositePreviewSurface = surface
        startPreviewWorkerIfNeeded()
        publishStatus()
    }

    fun detachCompositePreviewSurface() {
        if (pipelineHandle == 0L) return
        if (!compositePreviewAttached && compositePreviewSurface == null) {
            V2AppLog.d(TAG, "detach composite preview skipped: already detached")
            return
        }
        compositePreviewAttached = false
        compositePreviewSurface = null
        V2AppLog.d(TAG, "detach composite preview")
        nativeCompositor.detachCompositePreview()
        startPreviewWorkerIfNeeded()
        publishStatus()
    }

    fun reattachCompositePreviewSurface() {
        val surface = compositePreviewSurface?.takeIf { it.isValid } ?: return
        if (released() || pipelineHandle == 0L || !cameraAccessAllowed()) return
        if (compositePreviewAttached) {
            V2AppLog.d(TAG, "reattach composite preview skipped: already attached")
            startPreviewWorkerIfNeeded()
            publishStatusIfNeeded()
            return
        }
        V2AppLog.w(TAG, "reattach composite preview")
        attachCompositePreviewSurface(surface)
    }

    fun attachPreviewSurface(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false) {
        val slot = slots.getOrNull(index) ?: return
        if (released() || pipelineHandle == 0L) return
        if (!cameraAccessAllowed()) {
            V2AppLog.w(TAG, "attach preview skipped: screen is off ${slot.spec.name}/${slot.spec.cameraId}")
            return
        }

        V2AppLog.d(TAG, "attach preview ${slot.spec.name}/${slot.spec.cameraId}")
        if (!nativeCompositor.attachPreview(index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye)) {
            slot.previewAttached = false
            V2AppLog.e(TAG, "attach preview failed ${slot.spec.name}/${slot.spec.cameraId}: ${nativeCompositor.lastError()}")
            startPreviewWorkerIfNeeded()
            publishStatus()
            return
        }
        slot.previewAttached = true
        startPreviewWorkerIfNeeded()
        publishStatus()
    }

    fun detachPreviewSurface(index: Int) {
        val slot = slots.getOrNull(index) ?: return
        if (pipelineHandle == 0L) return
        slot.previewAttached = false
        V2AppLog.d(TAG, "detach preview ${slot.spec.name}/${slot.spec.cameraId}")
        nativeCompositor.detachPreview(index)
        startPreviewWorkerIfNeeded()
        statusFormatter.resetSlot(slot.index, slot.frameSignals, slot.renderedFrames)
        publishStatus()
    }

    fun attachSecondaryPreviewSurface(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false, rotation: Int = 0): Boolean {
        if (released() || pipelineHandle == 0L) return false
        V2AppLog.d(TAG, "attach secondary preview index=$index rotation=$rotation")
        if (!nativeCompositor.attachSecondaryPreview(index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye, rotation)) {
            V2AppLog.e(TAG, "attach secondary preview failed index=$index: ${nativeCompositor.lastError()}")
            return false
        }
        startPreviewWorkerIfNeeded()
        return true
    }

    fun detachSecondaryPreviewSurface(index: Int): Boolean {
        if (pipelineHandle == 0L) return false
        V2AppLog.d(TAG, "detach secondary preview index=$index")
        nativeCompositor.detachSecondaryPreview(index)
        return true
    }

    fun setSecondaryPreviewCorrection(index: Int, scaleX: Float, scaleY: Float, translateX: Float, translateY: Float, rotation: Float, mirrorH: Boolean, mirrorV: Boolean): Boolean {
        if (released() || pipelineHandle == 0L) return false
        return nativeCompositor.setSecondaryPreviewCorrection(index, scaleX, scaleY, translateX, translateY, rotation, mirrorH, mirrorV)
    }

    fun detachAttachedPreviewsForCameraStop() {
        val attachedPreviewIndexes = slots.filter { it.previewAttached }.map { it.index }.toIntArray()
        if (attachedPreviewIndexes.isNotEmpty()) {
            runCatching { nativeCompositor.detachPreviews(attachedPreviewIndexes) }
                .onFailure { V2AppLog.e(TAG, "batch detach preview failed", it) }
        }
        slots.forEach { slot ->
            if (slot.previewAttached) slot.previewAttached = false
        }
    }

    fun setPreviewRenderingEnabled(enabled: Boolean) {
        if (previewRenderingEnabled == enabled) return
        previewRenderingEnabled = enabled
        V2AppLog.d(TAG, "previewRenderingEnabled=$enabled")
        if (enabled) {
            startPreviewWorkerIfNeeded()
        } else {
            runCatching { nativeCompositor.stopPreviewWorker() }
            renderHandler.post {
                if (previewRenderingEnabled) return@post
                slots.forEach { slot ->
                    slot.lastRenderMs = 0L
                    slot.lastPreviewError = "paused"
                }
                publishStatusIfNeeded()
            }
        }
    }

    fun startPreviewWorkerIfNeeded() {
        if (!previewRenderingEnabled || released() || pipelineHandle == 0L) return
        if (!hasAttachedPreviewSurface()) {
            runCatching { nativeCompositor.stopPreviewWorker() }
                .onFailure { V2AppLog.w(TAG, "stop idle preview worker after surface mutation failed", it) }
            return
        }
        runCatching { nativeCompositor.startPreviewWorker(previewMaxFps) }
            .onFailure { V2AppLog.w(TAG, "restart preview worker after surface mutation failed", it) }
    }

    fun stopPreviewWorkerForCameraMutation(reason: String) {
        if (pipelineHandle == 0L) return
        runCatching { nativeCompositor.stopPreviewWorker(CAMERA_MUTATION_WORKER_STOP_TIMEOUT_MS) }
            .onFailure { V2AppLog.w(TAG, "stop preview worker for camera mutation failed reason=$reason", it) }
    }

    fun stopPreviewWorkerForRelease() {
        runCatching { nativeCompositor.stopPreviewWorker() }
    }

    fun isCompositePreviewAttached(): Boolean = compositePreviewAttached

    private fun hasAttachedPreviewSurface(): Boolean = compositePreviewAttached || slots.any { it.previewAttached }

    private companion object {
        private const val TAG = "V2CameraEngine"
        private const val CAMERA_MUTATION_WORKER_STOP_TIMEOUT_MS = 2_000L
    }
}
