package com.kooo.evcam.v2.service.camera

import android.content.Context
import android.os.SystemClock
import android.util.Size
import android.view.Surface
import com.kooo.evcam.v2.log.V2AppLog
import com.kooo.evcam.v2.nativebridge.V2NativeCompositor
import com.kooo.evcam.v2.service.V2CameraHealthSnapshot
import com.kooo.evcam.v2.settings.V2SettingsSnapshot
import com.kooo.evcam.v2.storage.V2StoragePathHelper

internal class V2CameraEngineComponentGraph(
    private val context: Context,
    private val listener: V2CameraEngine.Listener?,
) {
    private val env = V2CameraEngineEnvironment.create(context)
    private val specSet = env.specSet
    private val specs = env.specs
    private val cameraManager = env.cameraManager
    private val mainHandler = env.mainHandler
    private val renderHandler = env.renderHandler
    private val recordingSize = env.recordingSize
    private val compositeOutputSize = env.compositeOutputSize
    private val recordingFps = env.recordingFps
    private val previewMaxFps = env.previewMaxFps
    private val segmentDurationMs = env.segmentDurationMs
    private val recordingBitrate = env.recordingBitrate
    private val nativeCompositor = env.nativeCompositor
    private val pipelineHandle = env.pipelineHandle
    private val statusFormatter = V2CameraStatusFormatter(compositeOutputSize, recordingFps)
    private val slots = specs.mapIndexed { index, spec -> V2CameraSlot(index, spec, nativeCompositor, recordingSize, renderHandler) }
    private var lastPreviewDebugUpdateMs = 0L
    @Volatile private var cameraAccessAllowed = true
    @Volatile private var released = false
    @Volatile private var cameraGeneration = 0

    private val nativeRuntimeController = V2CameraNativeRuntimeController(
        context = context,
        nativeCompositor = nativeCompositor,
        pipelineHandle = pipelineHandle,
        recordingSize = compositeOutputSize,
        recordingFps = recordingFps,
        previewMaxFps = previewMaxFps,
        slots = slots,
    )
    private val previewSurfaceController = V2CameraPreviewSurfaceController(
        nativeCompositor = nativeCompositor,
        pipelineHandle = pipelineHandle,
        slots = slots,
        statusFormatter = statusFormatter,
        renderHandler = renderHandler,
        previewMaxFps = previewMaxFps,
        cameraAccessAllowed = { cameraAccessAllowed },
        released = { released },
        publishStatus = { publishStatus() },
        publishStatusIfNeeded = { publishStatusIfNeeded() },
    )
    private val recordingController = V2CameraRecordingController(
        context = context,
        mainHandler = mainHandler,
        renderHandler = renderHandler,
        nativeCompositor = nativeCompositor,
        pipelineHandle = pipelineHandle,
        outputSize = compositeOutputSize,
        bitrate = recordingBitrate,
        fps = recordingFps,
        segmentDurationMs = segmentDurationMs,
        previewMaxFps = previewMaxFps,
        cameraAccessAllowed = { cameraAccessAllowed },
        released = { released },
        openCameraCount = { slots.count { it.nativeCameraHandle != 0L } },
        expectedCameraCount = { slots.size },
        outputDir = { outputDir() },
        configureNativeRuntime = { logPrefix -> nativeRuntimeController.configure(logPrefix = logPrefix) },
        restartAttachedPreviews = { restartAttachedPreviewsAfterRecordingStop() },
        startPreviewWorkerIfNeeded = { previewSurfaceController.startPreviewWorkerIfNeeded() },
        requestCameraRecovery = { reason -> recoverCamerasForRecordingStart(reason) },
        publishStatus = { publishStatus() },
    )
    private val statusController = V2CameraEngineStatusController(
        slots = slots,
        pipelineHandle = pipelineHandle,
        fallbackInputSize = recordingSize,
        compositeOutputSize = compositeOutputSize,
        statusFormatter = statusFormatter,
        recordingController = recordingController,
        cameraAccessAllowed = { cameraAccessAllowed },
        released = { released },
        compositePreviewAttached = { previewSurfaceController.isCompositePreviewAttached() },
    )
    private val slotLifecycle = V2CameraSlotLifecycle(
        cameraManager = cameraManager,
        pipelineHandle = pipelineHandle,
        cameraAccessAllowed = { cameraAccessAllowed },
        released = { released },
        cameraGeneration = { cameraGeneration },
        targetPreviewFps = previewMaxFps,
        publishStatus = { publishStatus() },
    )
    private val slotSetController = V2CameraSlotSetController(
        cameraManager = cameraManager,
        pipelineHandle = pipelineHandle,
        specs = specs,
        slots = slots,
        slotLifecycle = slotLifecycle,
        previewSurfaceController = previewSurfaceController,
        cameraAccessAllowed = { cameraAccessAllowed },
        released = { released },
        bumpCameraGeneration = { cameraGeneration += 1 },
        publishStatus = { publishStatus() },
    )
    private val accessController = V2CameraAccessController(
        slots = slots,
        recordingController = recordingController,
        cameraAccessAllowed = { cameraAccessAllowed },
        setCameraAccessAllowed = { allowed -> cameraAccessAllowed = allowed },
        bumpCameraGeneration = { cameraGeneration += 1 },
        startCameras = { slotSetController.startCameras() },
        stopRecording = { recordingController.stop() },
        stopCameras = { slotSetController.stopCameras() },
        publishStatus = { publishStatus() },
    )

    init {
        V2AppLog.i("V2CameraEngine", "init model=${specSet.modelLabel} specs=${specs.joinToString { "${it.label}:${it.cameraId}/rot${it.rotation}" }} perCameraSize=${recordingSize.width}x${recordingSize.height} outputSize=${compositeOutputSize.width}x${compositeOutputSize.height} bitrate=$recordingBitrate fps=$recordingFps previewMaxFps=$previewMaxFps segmentMs=$segmentDurationMs codec=H.264 pipelineHandle=$pipelineHandle nativeLoaded=${V2NativeCompositor.isNativeLoaded()}")
        if (!nativeCompositor.isAvailable) V2AppLog.e("V2CameraEngine", "create compositor failed: ${V2NativeCompositor.nativeSummary()} lastError=${V2NativeCompositor.lastError()}")
        nativeRuntimeController.configure(logPrefix = "init")
        previewSurfaceController.startPreviewWorkerIfNeeded()
    }

    fun applyFisheyeSettings(fisheye: V2SettingsSnapshot.Fisheye? = null) {
        if (pipelineHandle == 0L) return
        nativeRuntimeController.configure(logPrefix = "fisheye", fisheye = fisheye)
        publishStatus()
    }

    fun setCameraAccessAllowed(allowed: Boolean) {
        accessController.setAllowed(allowed)
    }

    fun stopRecordingAndReleaseCameras(reason: String) {
        accessController.stopRecordingAndReleaseCameras(reason)
    }

    fun startCameras() {
        slotSetController.startCameras()
    }

    fun stopCameras() {
        slotSetController.stopCameras()
    }

    fun attachCompositePreviewSurface(surface: Surface) {
        previewSurfaceController.attachCompositePreviewSurface(surface)
    }

    fun detachCompositePreviewSurface() {
        previewSurfaceController.detachCompositePreviewSurface()
    }

    fun reattachCompositePreviewSurface() {
        previewSurfaceController.reattachCompositePreviewSurface()
    }

    fun attachPreviewSurface(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false) {
        previewSurfaceController.attachPreviewSurface(index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye)
    }

    fun detachPreviewSurface(index: Int) {
        previewSurfaceController.detachPreviewSurface(index)
    }

    fun attachSecondaryPreviewSurface(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false, rotation: Int = 0): Boolean {
        return previewSurfaceController.attachSecondaryPreviewSurface(index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye, rotation)
    }

    fun detachSecondaryPreviewSurface(index: Int): Boolean {
        return previewSurfaceController.detachSecondaryPreviewSurface(index)
    }

    fun setSecondaryPreviewCorrection(index: Int, scaleX: Float, scaleY: Float, translateX: Float, translateY: Float, rotation: Float, mirrorH: Boolean, mirrorV: Boolean): Boolean {
        return previewSurfaceController.setSecondaryPreviewCorrection(index, scaleX, scaleY, translateX, translateY, rotation, mirrorH, mirrorV)
    }

    fun previewIndexForPosition(position: String): Int? = statusController.previewIndexForPosition(position)

    fun previewDescription(index: Int): String = statusController.previewDescription(index)

    fun previewRenderedFrames(index: Int): Long = statusController.previewRenderedFrames(index)

    fun compositePreviewRenderedFrames(): Long = statusController.compositePreviewRenderedFrames()

    fun compositePreviewFpsMilli(): Long = statusController.compositePreviewFpsMilli()

    fun setPreviewRenderingEnabled(enabled: Boolean) {
        previewSurfaceController.setPreviewRenderingEnabled(enabled)
    }

    fun previewInputSizeLabel(index: Int): String = statusController.previewInputSizeLabel(index)

    fun compositePreviewSizeLabel(): String = statusController.compositePreviewSizeLabel()

    fun previewInputSize(index: Int): Size? = statusController.previewInputSize(index)

    fun startRecording() {
        recordingController.startNormalRecording()
    }

    fun stopRecordingBlockingForSwitch() {
        recordingController.stopBlockingForSwitch()
    }

    fun stopRecording() {
        recordingController.stop()
    }

    fun toggleRecording(): Boolean = recordingController.toggleRecording()

    fun isRecording(): Boolean = recordingController.isRecording

    fun isNormalRecording(): Boolean = recordingController.isNormalRecording

    fun statusText(): String = statusController.statusText()

    fun healthSnapshot(): V2CameraHealthSnapshot = statusController.healthSnapshot()

    fun release() {
        if (released) return
        V2AppLog.i("V2CameraEngine", "release")
        released = true
        cameraGeneration += 1
        recordingController.stopForRelease()
        previewSurfaceController.stopPreviewWorkerForRelease()
        slots.forEach { it.close() }
        runCatching { nativeCompositor.release() }
        env.quitRenderThread()
    }

    private fun outputDir() = V2StoragePathHelper.outputDir(context)

    private fun restartAttachedPreviewsAfterRecordingStop() {
        slots.forEach { if (it.previewAttached) slotLifecycle.restartPreviewAfterRecordingStop(it) }
    }

    private fun recoverCamerasForRecordingStart(reason: String) {
        if (!cameraAccessAllowed || released) return
        V2AppLog.w("V2CameraEngine", "recording start requested camera recovery reason=$reason")
        runCatching {
            slotSetController.stopCameras()
            slotSetController.startCameras()
            previewSurfaceController.startPreviewWorkerIfNeeded()
        }.onFailure { V2AppLog.e("V2CameraEngine", "recording start camera recovery failed reason=$reason", it) }
    }

    private fun publishStatusIfNeeded() {
        if (SystemClock.elapsedRealtime() - lastPreviewDebugUpdateMs < STATUS_DEBUG_MIN_INTERVAL_MS) return
        lastPreviewDebugUpdateMs = SystemClock.elapsedRealtime()
        publishStatus()
    }

    private fun publishStatus() {
        listener?.onStatusChanged(statusController.statusText())
    }

    private companion object {
        private const val STATUS_DEBUG_MIN_INTERVAL_MS = 1_000L
    }
}
