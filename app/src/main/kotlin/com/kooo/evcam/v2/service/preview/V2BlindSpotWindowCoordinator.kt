package com.kooo.evcam.v2.service.preview

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.provider.Settings
import android.util.Size
import android.view.Surface
import com.kooo.evcam.v2.log.V2AppLog
import com.kooo.evcam.v2.settings.V2BlindSpotSettings
import com.kooo.evcam.v2.ui.blindspot.V2BlindSpotOverlay
import com.kooo.evcam.v2.ui.blindspot.V2BlindSpotSmallWindowActivity

internal class V2BlindSpotWindowCoordinator(
    private val context: Context,
    private val handler: Handler,
    private val isDisplayPowerOn: () -> Boolean,
    private val isUiVisible: () -> Boolean,
    private val shouldAvoidWindow: () -> Boolean,
    private val avoidanceTarget: () -> String?,
    private val windowMode: () -> String,
    private val previewIndexForSide: (String) -> Int?,
    private val previewDescription: (Int) -> String,
    private val attachPreview: (Int, Surface) -> Unit,
    private val detachPreview: (Int) -> Unit,
    private val previewInputSize: (Int) -> Size?,
    private val renderedFrames: (Int) -> Long,
    private val restoreMainPreview: (Int) -> Unit,
    private val hideFisheyePreview: () -> Unit,
    private val hideUi: () -> Unit,
    private val showToast: (String) -> Unit,
    private val showSecondaryOverlay: (String) -> Unit = {},
    private val hideSecondaryOverlay: () -> Unit = {},
    private val hideDelayMs: () -> Long = { OFF_HIDE_DEBOUNCE_MS },
) {
    private var cameraIndex = -1
    private var activeSide: String? = null
    private var activeWindowMode: String? = null
    private var floatingOverlay: V2BlindSpotOverlay? = null
    @Volatile private var signalIsOff = true

    val activeCameraIndex: Int
        get() = cameraIndex

    fun showPreview(side: String) {
        val normalizedSide = if (side == "right") "right" else "left"
        if (!isDisplayPowerOn()) {
            V2AppLog.w(TAG, "blind spot preview skipped: display off side=$normalizedSide")
            return
        }
        cancelPendingShowHide()
        V2AppLog.i(TAG, "blind spot correction preview side=$normalizedSide")
        showNow(normalizedSide, forceRefresh = true)
    }

    fun handleTurnSignal(side: String, on: Boolean) {
        if (on) {
            signalIsOff = false
            cancelPendingShowHide()
            show(side)
            return
        }

        signalIsOff = true
        cancelPendingShowHide()
        val delay = hideDelayMs()
        handler.postDelayed({
            if (signalIsOff && activeSide == side) {
                hide()
                V2AppLog.i(TAG, "blind spot signal off side=$side, hide after ${delay}ms")
            } else {
                V2AppLog.i(TAG, "blind spot hide canceled: signal active again side=$side active=$activeSide")
            }
        }, HIDE_TOKEN, delay)
    }

    fun hide() {
        handler.removeCallbacksAndMessages(SHOW_TOKEN)
        val index = cameraIndex
        hideAllWindows()
        hideSecondaryOverlay()
        cameraIndex = -1
        activeSide = null
        activeWindowMode = null
        if (index >= 0 && isDisplayPowerOn()) restoreMainPreview(index)
        V2AppLog.i(TAG, "blind spot window hidden index=$index")
    }

    fun cancelAndHideForAvoidance() {
        cancelPendingShowHide()
        hide()
    }

    private fun show(side: String) {
        if (shouldAvoidWindow()) {
            V2AppLog.i(TAG, "blind spot show skipped: blind spot avoidance active target=${avoidanceTarget()} side=$side")
            handler.removeCallbacksAndMessages(SHOW_TOKEN)
            return
        }
        if (!isDisplayPowerOn()) {
            V2AppLog.w(TAG, "blind spot show skipped: display off side=$side")
            return
        }
        if (isUiVisible()) {
            V2AppLog.i(TAG, "blind spot hide preview UI before small window side=$side")
            hideUi()
            handler.removeCallbacksAndMessages(SHOW_TOKEN)
            handler.postDelayed({
                val avoid = shouldAvoidWindow()
                if (!signalIsOff && !avoid) {
                    showNow(side)
                } else if (avoid) {
                    V2AppLog.i(TAG, "blind spot delayed show canceled: blind spot avoidance active target=${avoidanceTarget()}")
                } else {
                    V2AppLog.i(TAG, "blind spot delayed show canceled: signal is off")
                }
            }, SHOW_TOKEN, SHOW_AFTER_UI_HIDE_MS)
            return
        }
        showNow(side)
    }

    private fun showNow(side: String, forceRefresh: Boolean = false) {
        val startedMs = SystemClock.elapsedRealtime()
        if (shouldAvoidWindow()) {
            V2AppLog.i(TAG, "blind spot showNow skipped: blind spot avoidance active target=${avoidanceTarget()} side=$side")
            return
        }
        val index = previewIndexForSide(side) ?: run {
            V2AppLog.w(TAG, "blind spot show skipped: no preview index for side=$side")
            return
        }
        val mode = normalizedWindowMode()
        if (mode == V2BlindSpotSettings.WINDOW_MODE_FLOATING_OVERLAY && !canDrawFloatingOverlay()) {
            V2AppLog.w(TAG, "blind spot floating overlay skipped: overlay permission missing side=$side index=$index")
            showToast("补盲悬浮窗需要悬浮窗权限")
            return
        }
        val previousIndex = cameraIndex
        val previousSide = activeSide
        val previousMode = activeWindowMode
        if (previousIndex == index && previousSide == side && previousMode == mode) {
            if (forceRefresh) {
                showWindow(mode, side, index)
                showSecondaryOverlay(side)
                V2AppLog.i(TAG, "blind spot window refreshed mode=$mode side=$side index=$index")
            } else {
                V2AppLog.i(TAG, "blind spot show skipped: already active mode=$mode side=$side index=$index")
            }
            return
        }
        hideFisheyePreview()
        cameraIndex = index
        activeSide = side
        activeWindowMode = mode
        V2AppLog.i(TAG, "blind spot show window mode=$mode side=$side ${previewDescription(index)}")
        if (previousIndex >= 0 && (previousIndex != index || previousSide != side || previousMode != mode)) {
            hideWindow(previousMode)
            handler.postDelayed({
                if (!forceRefresh && signalIsOff) {
                    V2AppLog.i(TAG, "blind spot recreate canceled: signal is off side=$side index=$index")
                    return@postDelayed
                }
                if (shouldAvoidWindow()) {
                    V2AppLog.i(TAG, "blind spot recreate canceled: blind spot avoidance active target=${avoidanceTarget()} side=$side")
                    return@postDelayed
                }
                if (cameraIndex != index || activeSide != side) {
                    V2AppLog.i(TAG, "blind spot recreate canceled: active target changed expected=$side/$index actual=$activeSide/$cameraIndex")
                    return@postDelayed
                }
                showWindow(mode, side, index)
                showSecondaryOverlay(side)
                if (previousIndex != index && isDisplayPowerOn()) restoreMainPreview(previousIndex)
                V2AppLog.i(TAG, "blind spot window recreated mode=$mode side=$side ${previewDescription(index)}")
            }, SHOW_TOKEN, recreateDelayMs(previousIndex, index, previousMode, mode))
        } else {
            showWindow(mode, side, index)
            showSecondaryOverlay(side)
        }
        V2AppLog.perf("V2BlindSpotPerf", "show", SystemClock.elapsedRealtime() - startedMs, "mode=$mode side=$side index=$index previous=$previousIndex")
    }

    private fun showWindow(mode: String, side: String, index: Int) {
        when (mode) {
            V2BlindSpotSettings.WINDOW_MODE_FLOATING_OVERLAY -> {
                V2BlindSpotSmallWindowActivity.finishActiveFromService()
                floatingOverlay().show(side, index)
            }
            else -> {
                floatingOverlay?.hide()
                V2BlindSpotSmallWindowActivity.show(context, side, index)
            }
        }
    }

    private fun hideWindow(mode: String?) {
        when (mode) {
            V2BlindSpotSettings.WINDOW_MODE_FLOATING_OVERLAY -> floatingOverlay?.hide()
            V2BlindSpotSettings.WINDOW_MODE_SYSTEM_SMALL_WINDOW -> V2BlindSpotSmallWindowActivity.finishActiveFromService()
            else -> hideAllWindows()
        }
    }

    private fun hideAllWindows() {
        floatingOverlay?.hide()
        V2BlindSpotSmallWindowActivity.finishActiveFromService()
    }

    private fun floatingOverlay(): V2BlindSpotOverlay {
        return floatingOverlay ?: V2BlindSpotOverlay(
            context = context,
            attachPreview = attachPreview,
            detachPreview = detachPreview,
            previewInputSize = previewInputSize,
            renderedFrames = renderedFrames,
            onClose = { hide() },
        ).also { floatingOverlay = it }
    }

    private fun normalizedWindowMode(): String {
        return if (windowMode() == V2BlindSpotSettings.WINDOW_MODE_FLOATING_OVERLAY) {
            V2BlindSpotSettings.WINDOW_MODE_FLOATING_OVERLAY
        } else {
            V2BlindSpotSettings.WINDOW_MODE_SYSTEM_SMALL_WINDOW
        }
    }

    private fun canDrawFloatingOverlay(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

    private fun recreateDelayMs(previousIndex: Int, index: Int, previousMode: String?, mode: String): Long {
        if (previousIndex == index && previousMode != mode) return RECREATE_SAME_INDEX_WINDOW_DELAY_MS
        return RECREATE_SMALL_WINDOW_DELAY_MS
    }

    private fun cancelPendingShowHide() {
        handler.removeCallbacksAndMessages(HIDE_TOKEN)
        handler.removeCallbacksAndMessages(SHOW_TOKEN)
    }

    private companion object {
        private const val TAG = "V2CameraService"
        private const val HIDE_TOKEN = "blind_spot_hide"
        private const val SHOW_TOKEN = "blind_spot_show"
        private const val SHOW_AFTER_UI_HIDE_MS = 300L
        private const val RECREATE_SMALL_WINDOW_DELAY_MS = 0L
        private const val RECREATE_SAME_INDEX_WINDOW_DELAY_MS = 120L
        private const val OFF_HIDE_DEBOUNCE_MS = 500L
    }
}
