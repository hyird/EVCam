package com.kooo.evcam.v2.service.preview

import android.content.Context
import android.os.Handler
import android.util.Size
import android.view.Surface
import com.kooo.evcam.v2.log.V2AppLog
import com.kooo.evcam.v2.settings.V2BlindSpotCorrection
import com.kooo.evcam.v2.settings.V2BlindSpotSettings
import com.kooo.evcam.v2.settings.V2SettingsRepository
import com.kooo.evcam.v2.settings.V2SettingsSnapshot
import com.kooo.evcam.v2.ui.blindspot.V2BlindSpotSecondaryDisplayOverlay

class V2BlindSpotController(
    private val context: Context,
    private val handler: Handler,
    isDisplayPowerOn: () -> Boolean,
    isUiVisible: () -> Boolean,
    shouldAvoidWindow: () -> Boolean,
    avoidanceTarget: () -> String?,
    previewIndexForSide: (String) -> Int?,
    previewDescription: (Int) -> String,
    attachPreview: (Int, Surface) -> Unit,
    detachPreview: (Int) -> Unit,
    previewInputSize: (Int) -> Size?,
    renderedFrames: (Int) -> Long,
    restoreMainPreview: (Int) -> Unit,
    hideFisheyePreview: () -> Unit,
    hideUi: () -> Unit,
    showToast: (String) -> Unit,
    private val attachSecondaryPreview: (Int, Surface, Int) -> Boolean,
    private val detachSecondaryPreview: (Int) -> Boolean,
    private val setSecondaryPreviewCorrection: (Int, V2BlindSpotCorrection) -> Boolean,
) {
    @Volatile private var config: V2SettingsSnapshot.BlindSpot = V2SettingsRepository.blindSpotConfig(context)
    private val secondaryOverlay = V2BlindSpotSecondaryDisplayOverlay(context.applicationContext)
    private var secondaryCameraIndex: Int = -1
    private var secondaryActiveSide: String? = null
    private val windowCoordinator = V2BlindSpotWindowCoordinator(
        context = context,
        handler = handler,
        isDisplayPowerOn = isDisplayPowerOn,
        isUiVisible = isUiVisible,
        shouldAvoidWindow = shouldAvoidWindow,
        avoidanceTarget = avoidanceTarget,
        windowMode = { config.windowMode },
        previewIndexForSide = previewIndexForSide,
        previewDescription = previewDescription,
        attachPreview = attachPreview,
        detachPreview = detachPreview,
        previewInputSize = previewInputSize,
        renderedFrames = renderedFrames,
        restoreMainPreview = restoreMainPreview,
        hideFisheyePreview = hideFisheyePreview,
        hideUi = hideUi,
        showToast = showToast,
        showSecondaryOverlay = { side -> showSecondaryDisplay(side) },
        hideSecondaryOverlay = { hideSecondaryDisplay() },
        hideDelayMs = { config.hideDelayMs },
    )
    private val signalObserver = V2BlindSpotSignalObserver { side, on -> handleTurnSignal(side, on) }

    val activeCameraIndex: Int
        get() = windowCoordinator.activeCameraIndex

    fun startObserver() {
        signalObserver.start(config)
    }

    fun updateConfig(next: V2SettingsSnapshot.BlindSpot) {
        val old = config
        config = next
        if (!next.enabled) hide()
        if (!next.enabled || !next.secondaryDisplay.enabled) hideSecondaryDisplay()
        // Re-apply correction to secondary display when config changes
        val idx = secondaryCameraIndex
        val side = secondaryActiveSide
        if (idx >= 0 && side != null && secondaryOverlay.isShowing()) {
            applySecondaryCorrectionIfNeeded(idx, side)
        }
        if (old != next) {
            V2AppLog.i(TAG, "blind spot config updated enabled=${next.enabled} propId=${next.turnSignalPropId} correction=${next.correctionEnabled} windowMode=${next.windowMode} secondaryDisplay=${next.secondaryDisplay.enabled}")
        }
    }

    fun stopObserver() {
        signalObserver.stop()
    }

    fun restartObserver(next: V2SettingsSnapshot.BlindSpot = V2SettingsRepository.blindSpotConfig(context)) {
        V2AppLog.i(TAG, "refresh blind spot observer")
        updateConfig(next)
        stopObserver()
        hide()
        startObserver()
    }

    fun showPreview(side: String) {
        windowCoordinator.showPreview(side)
    }

    fun hide() {
        windowCoordinator.hide()
    }

    fun cancelAndHideForAvoidance() {
        windowCoordinator.cancelAndHideForAvoidance()
    }

    private fun showSecondaryDisplay(side: String) {
        val sd = config.secondaryDisplay
        if (!sd.enabled || sd.displayId < 0) return
        val cameraIndex = windowCoordinator.activeCameraIndex
        if (cameraIndex < 0) return
        secondaryCameraIndex = cameraIndex
        secondaryActiveSide = side
        secondaryOverlay.show(
            displayId = sd.displayId,
            x = sd.x,
            y = sd.y,
            width = sd.width,
            height = sd.height,
            rotation = sd.rotation,
            showBorder = sd.showBorder,
            onSurfaceReady = { surface ->
                handler.post {
                    if (secondaryCameraIndex == cameraIndex && secondaryActiveSide == side && secondaryOverlay.isShowing()) {
                        val attached = attachSecondaryPreview(cameraIndex, surface, sd.rotation)
                        if (attached) {
                            applySecondaryCorrectionIfNeeded(cameraIndex, side)
                            V2AppLog.i(TAG, "secondary preview attached index=$cameraIndex rotation=${sd.rotation}")
                        } else {
                            V2AppLog.w(TAG, "secondary preview attach failed index=$cameraIndex rotation=${sd.rotation}")
                        }
                    }
                }
            },
            onSurfaceDestroyed = {
                handler.post {
                    detachSecondaryPreview(cameraIndex)
                    V2AppLog.i(TAG, "secondary preview detached index=$cameraIndex")
                }
            },
        )
        V2AppLog.i(TAG, "secondary display shown side=$side displayId=${sd.displayId} cameraIndex=$cameraIndex")
    }

    private fun hideSecondaryDisplay() {
        val idx = secondaryCameraIndex
        if (idx >= 0) {
            detachSecondaryPreview(idx)
            secondaryCameraIndex = -1
        }
        secondaryActiveSide = null
        secondaryOverlay.hide()
    }

    private fun applySecondaryCorrectionIfNeeded(index: Int, side: String) {
        if (!config.correctionEnabled) return
        val correction = V2BlindSpotSettings.correction(context, side)
        setSecondaryPreviewCorrection(index, correction)
        V2AppLog.i(TAG, "secondary correction applied index=$index side=$side correction=$correction")
    }

    private fun handleTurnSignal(side: String, on: Boolean) {
        handler.post {
            if (!config.enabled) return@post
            windowCoordinator.handleTurnSignal(side, on)
        }
    }

    private companion object {
        private const val TAG = "V2CameraService"
    }
}
