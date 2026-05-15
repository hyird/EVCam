package com.kooo.evcam.v2.nativebridge

import android.graphics.SurfaceTexture
import android.util.Size
import android.view.Surface
import com.kooo.evcam.v2.log.V2AppLog

class V2NativeCompositor private constructor(val handle: Long) {
    val isAvailable: Boolean get() = handle != 0L

    data class FisheyeRuntimeArrays(
        val enabled: BooleanArray,
        val k1: FloatArray,
        val k2: FloatArray,
        val k3: FloatArray,
        val k4: FloatArray,
        val zoom: FloatArray,
        val centerX: FloatArray,
        val centerY: FloatArray,
        val fx: FloatArray,
        val fy: FloatArray,
        val sourceWidth: FloatArray,
        val sourceHeight: FloatArray,
    )

    data class RuntimeConfig(
        val width: Int,
        val height: Int,
        val previewFps: Int,
        val encoderFps: Int,
        val sideLeftRotation: Int,
        val sideRightRotation: Int,
        val layoutMode: Int,
        val fisheye: FisheyeRuntimeArrays,
        val blindSpotFisheye: FisheyeRuntimeArrays,
    )

    fun configureRuntime(config: RuntimeConfig): Boolean = isAvailable && GlesNative.setCompositorRuntimeConfig(
        handle,
        config.width,
        config.height,
        config.previewFps,
        config.encoderFps,
        config.sideLeftRotation,
        config.sideRightRotation,
        config.layoutMode,
        config.fisheye.enabled,
        config.fisheye.k1,
        config.fisheye.k2,
        config.fisheye.k3,
        config.fisheye.k4,
        config.fisheye.zoom,
        config.fisheye.centerX,
        config.fisheye.centerY,
        config.fisheye.fx,
        config.fisheye.fy,
        config.fisheye.sourceWidth,
        config.fisheye.sourceHeight,
        config.blindSpotFisheye.enabled,
        config.blindSpotFisheye.k1,
        config.blindSpotFisheye.k2,
        config.blindSpotFisheye.k3,
        config.blindSpotFisheye.k4,
        config.blindSpotFisheye.zoom,
        config.blindSpotFisheye.centerX,
        config.blindSpotFisheye.centerY,
        config.blindSpotFisheye.fx,
        config.blindSpotFisheye.fy,
        config.blindSpotFisheye.sourceWidth,
        config.blindSpotFisheye.sourceHeight
    )

    fun attachPreview(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false): Boolean =
        isAvailable && GlesNative.attachPreviewSurfaceWithMode(handle, index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye)
    fun attachCompositePreview(surface: Surface): Boolean =
        isAvailable && GlesNative.attachCompositePreviewSurface(handle, surface)
    fun detachCompositePreview(): Boolean = isAvailable && GlesNative.detachCompositePreviewSurface(handle)
    fun attachSecondaryPreview(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false, rotation: Int = 0): Boolean =
        isAvailable && GlesNative.attachSecondaryPreviewSurface(handle, index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye, rotation)
    fun detachSecondaryPreview(index: Int): Boolean = isAvailable && GlesNative.detachSecondaryPreviewSurface(handle, index)
    fun setSecondaryPreviewCorrection(index: Int, scaleX: Float, scaleY: Float, translateX: Float, translateY: Float, rotation: Float, mirrorH: Boolean, mirrorV: Boolean): Boolean =
        isAvailable && GlesNative.setSecondaryPreviewCorrection(handle, index, scaleX, scaleY, translateX, translateY, rotation, mirrorH, mirrorV)
    fun detachPreview(index: Int): Boolean = isAvailable && GlesNative.detachPreviewSurface(handle, index)
    fun detachPreviews(indexes: IntArray): Boolean = indexes.isEmpty() || (isAvailable && GlesNative.detachPreviewSurfaces(handle, indexes))
    fun setPreviewMaxFps(fps: Int): Boolean = isAvailable && GlesNative.setPreviewMaxFps(handle, fps)
    fun startPreviewWorker(fps: Int): Boolean = isAvailable && GlesNative.startPreviewWorker(handle, fps)
    fun stopPreviewWorker(timeoutMs: Long = 1_000L): Boolean = isAvailable && GlesNative.stopPreviewWorker(handle, timeoutMs)
    fun createOesTexture(index: Int): Int = if (isAvailable) GlesNative.createOesTexture(handle, index) else 0
    fun createOesInput(index: Int, surfaceTexture: SurfaceTexture): Boolean = isAvailable && GlesNative.createOesInput(handle, index, surfaceTexture)
    fun markOesFrameAvailable(index: Int): Boolean = isAvailable && GlesNative.markOesFrameAvailable(handle, index)
    fun destroyOesInput(index: Int): Boolean = isAvailable && GlesNative.destroyOesInput(handle, index)
    fun release() { if (isAvailable) GlesNative.releaseCompositor(handle) }
    fun lastError(): String = GlesNative.getLastError()

    companion object {
        fun create(size: Size): V2NativeCompositor {
            if (!GlesNative.isLoaded) {
                V2AppLog.e("V2NativeCompositor", "native library unavailable: ${GlesNative.summaryOrFallback()}")
                return V2NativeCompositor(0L)
            }
            val handle = runCatching { GlesNative.createCompositor(size.width, size.height) }
                .onFailure { V2AppLog.e("V2NativeCompositor", "create compositor crashed", it) }
                .getOrDefault(0L)
            return V2NativeCompositor(handle)
        }

        fun nativeSummary(): String = GlesNative.summaryOrFallback()
        fun lastError(): String = GlesNative.getLastError()
        fun isNativeLoaded(): Boolean = GlesNative.isLoaded
    }
}
