package com.kooo.evcam.v2.nativebridge

import android.graphics.Bitmap
import android.view.Surface
import com.kooo.evcam.v2.log.V2AppLog

object GlesNative {
    val isLoaded: Boolean
    val loadError: Throwable?

    init {
        var error: Throwable? = null
        val loaded = try {
            System.loadLibrary("evcam_gles_compositor")
            true
        } catch (t: Throwable) {
            error = t
            false
        }
        isLoaded = loaded
        loadError = error
        if (loaded) {
            V2AppLog.i("GlesNative", "native library loaded")
        } else {
            V2AppLog.e("GlesNative", "native library load failed", error)
        }
    }

    external fun getGlesSummary(): String
    external fun createCompositor(width: Int, height: Int): Long
    external fun createOesTexture(handle: Long, index: Int): Int
    external fun destroyOesInput(handle: Long, index: Int): Boolean
    external fun setCompositorRuntimeConfig(
        handle: Long,
        width: Int,
        height: Int,
        previewFps: Int,
        encoderFps: Int,
        sideLeftRotation: Int,
        sideRightRotation: Int,
        layoutMode: Int,
        fisheyeEnabled: BooleanArray,
        k1: FloatArray,
        k2: FloatArray,
        k3: FloatArray,
        k4: FloatArray,
        zoom: FloatArray,
        centerX: FloatArray,
        centerY: FloatArray,
        fx: FloatArray,
        fy: FloatArray,
        sourceWidth: FloatArray,
        sourceHeight: FloatArray,
        blindSpotFisheyeEnabled: BooleanArray,
        blindSpotK1: FloatArray,
        blindSpotK2: FloatArray,
        blindSpotK3: FloatArray,
        blindSpotK4: FloatArray,
        blindSpotZoom: FloatArray,
        blindSpotCenterX: FloatArray,
        blindSpotCenterY: FloatArray,
        blindSpotFx: FloatArray,
        blindSpotFy: FloatArray,
        blindSpotSourceWidth: FloatArray,
        blindSpotSourceHeight: FloatArray
    ): Boolean
    external fun setPreviewMaxFps(handle: Long, fps: Int): Boolean
    external fun startPreviewWorker(handle: Long, fps: Int): Boolean
    external fun stopPreviewWorker(handle: Long, timeoutMs: Long): Boolean
    external fun startManagedRecording(
        handle: Long,
        outputDir: String,
        suffix: String,
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Int,
        segmentDurationMs: Long,
        wallClockMs: Long,
        reservedBytes: Long,
        availableBytes: Long,
    ): Boolean
    external fun stopManagedRecording(handle: Long, timeoutMs: Long, stopWallClockMs: Long): Boolean
    external fun snapshotRecordingWorker(handle: Long): LongArray
    external fun updateWatermarkBitmap(handle: Long, bitmap: Bitmap, x: Int, y: Int): Boolean
    external fun clearWatermarkBitmap(handle: Long): Boolean
    external fun createNativeCameraPreview(
        cameraId: String,
        surface: Surface,
        nativeHandle: Long,
        inputIndex: Int,
        fpsRangeLower: Int,
        fpsRangeUpper: Int,
    ): Long
    external fun releaseNativeCameraPreview(cameraHandle: Long): Boolean
    external fun nativePrepareSegmentCacheCallback(): Boolean
    external fun nativeCleanupStorage(outputDir: String, reservedBytes: Long, availableBytes: Long): LongArray
    external fun nativeListPlaybackVideos(scanDirs: Array<String>): Array<String>
    external fun nativeListPlaybackImages(scanDirs: Array<String>): Array<String>
    external fun nativeBuildPlaybackCache(scanDirs: Array<String>): String?
    external fun nativeBuildPlaybackCacheWithThumbnails(scanDirs: Array<String>): String?
    external fun nativeBuildPlaybackEntry(videoPath: String): String?
    external fun nativeEnsurePlaybackThumbnail(videoPath: String): String?
    external fun nativeDeleteVideoAndSidecars(videoPath: String): Boolean
    external fun nativeDeleteVideosAndBuildPlaybackCache(videoPaths: Array<String>, scanDirs: Array<String>): String?
    external fun createOesInput(handle: Long, index: Int, surfaceTexture: android.graphics.SurfaceTexture): Boolean
    external fun markOesFrameAvailable(handle: Long, index: Int): Boolean
    external fun attachCompositePreviewSurface(handle: Long, surface: Surface): Boolean
    external fun detachCompositePreviewSurface(handle: Long): Boolean
    external fun attachPreviewSurfaceWithMode(handle: Long, index: Int, surface: Surface, applyFisheye: Boolean, applyNativeTransform: Boolean, useBlindSpotFisheye: Boolean): Boolean
    external fun detachPreviewSurface(handle: Long, index: Int): Boolean
    external fun detachPreviewSurfaces(handle: Long, indexes: IntArray): Boolean
    external fun attachSecondaryPreviewSurface(handle: Long, index: Int, surface: Surface, applyFisheye: Boolean, applyNativeTransform: Boolean, useBlindSpotFisheye: Boolean, rotation: Int): Boolean
    external fun detachSecondaryPreviewSurface(handle: Long, index: Int): Boolean
    external fun setSecondaryPreviewCorrection(handle: Long, index: Int, scaleX: Float, scaleY: Float, translateX: Float, translateY: Float, rotation: Float, mirrorH: Boolean, mirrorV: Boolean): Boolean
    external fun releaseCompositor(handle: Long)
    external fun getMetricsSnapshot(handle: Long): LongArray
    external fun getLastError(): String

    fun summaryOrFallback(): String {
        return if (isLoaded) {
            runCatching { getGlesSummary() }.getOrElse { "GLES native error: ${it.message}" }
        } else {
            "GLES native not loaded: ${loadError?.message ?: "unknown"}"
        }
    }
}
