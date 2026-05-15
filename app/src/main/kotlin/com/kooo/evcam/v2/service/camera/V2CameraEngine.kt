package com.kooo.evcam.v2.service.camera

import android.content.Context
import android.util.Size
import android.view.Surface
import com.kooo.evcam.v2.service.V2CameraHealthSnapshot
import com.kooo.evcam.v2.settings.V2SettingsSnapshot

class V2CameraEngine(context: Context, listener: Listener? = null) {
    interface Listener {
        fun onStatusChanged(status: String)
    }

    private val graph = V2CameraEngineComponentGraph(context, listener)

    fun applyFisheyeSettings(fisheye: V2SettingsSnapshot.Fisheye? = null) {
        graph.applyFisheyeSettings(fisheye)
    }

    fun setCameraAccessAllowed(allowed: Boolean) {
        graph.setCameraAccessAllowed(allowed)
    }

    fun stopRecordingAndReleaseCameras(reason: String) {
        graph.stopRecordingAndReleaseCameras(reason)
    }

    fun startCameras() {
        graph.startCameras()
    }

    fun stopCameras() {
        graph.stopCameras()
    }

    fun attachCompositePreviewSurface(surface: Surface) {
        graph.attachCompositePreviewSurface(surface)
    }

    fun detachCompositePreviewSurface() {
        graph.detachCompositePreviewSurface()
    }

    fun reattachCompositePreviewSurface() {
        graph.reattachCompositePreviewSurface()
    }

    fun attachPreviewSurface(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false) {
        graph.attachPreviewSurface(index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye)
    }

    fun detachPreviewSurface(index: Int) {
        graph.detachPreviewSurface(index)
    }

    fun attachSecondaryPreviewSurface(index: Int, surface: Surface, applyFisheye: Boolean = true, applyNativeTransform: Boolean = true, useBlindSpotFisheye: Boolean = false, rotation: Int = 0): Boolean {
        return graph.attachSecondaryPreviewSurface(index, surface, applyFisheye, applyNativeTransform, useBlindSpotFisheye, rotation)
    }

    fun detachSecondaryPreviewSurface(index: Int): Boolean {
        return graph.detachSecondaryPreviewSurface(index)
    }

    fun setSecondaryPreviewCorrection(index: Int, scaleX: Float, scaleY: Float, translateX: Float, translateY: Float, rotation: Float, mirrorH: Boolean, mirrorV: Boolean): Boolean {
        return graph.setSecondaryPreviewCorrection(index, scaleX, scaleY, translateX, translateY, rotation, mirrorH, mirrorV)
    }

    fun previewIndexForPosition(position: String): Int? = graph.previewIndexForPosition(position)

    fun previewDescription(index: Int): String = graph.previewDescription(index)

    fun previewRenderedFrames(index: Int): Long = graph.previewRenderedFrames(index)

    fun compositePreviewRenderedFrames(): Long = graph.compositePreviewRenderedFrames()

    fun compositePreviewFpsMilli(): Long = graph.compositePreviewFpsMilli()

    fun setPreviewRenderingEnabled(enabled: Boolean) {
        graph.setPreviewRenderingEnabled(enabled)
    }

    fun previewInputSizeLabel(index: Int): String = graph.previewInputSizeLabel(index)

    fun compositePreviewSizeLabel(): String = graph.compositePreviewSizeLabel()

    fun previewInputSize(index: Int): Size? = graph.previewInputSize(index)

    fun startRecording() {
        graph.startRecording()
    }

    fun stopRecordingBlockingForSwitch() {
        graph.stopRecordingBlockingForSwitch()
    }

    fun stopRecording() {
        graph.stopRecording()
    }

    fun toggleRecording(): Boolean = graph.toggleRecording()

    fun isRecording(): Boolean = graph.isRecording()

    fun isNormalRecording(): Boolean = graph.isNormalRecording()

    fun statusText(): String = graph.statusText()

    fun healthSnapshot(): V2CameraHealthSnapshot = graph.healthSnapshot()

    fun release() {
        graph.release()
    }
}
