package com.kooo.evcam.v2.ui.blindspot

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import com.kooo.evcam.v2.log.V2AppLog

class V2BlindSpotSecondaryDisplayOverlay(private val appContext: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    @Volatile private var showing = false
    private var onSurfaceReady: ((Surface) -> Unit)? = null
    private var onSurfaceDestroyed: (() -> Unit)? = null
    private var generation = 0

    fun show(
        displayId: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        rotation: Int,
        showBorder: Boolean,
        onSurfaceReady: (Surface) -> Unit,
        onSurfaceDestroyed: () -> Unit,
    ) {
        mainHandler.post {
            generation++
            val gen = generation

            // Tear down old overlay — fires old onSurfaceDestroyed to detach native
            tearDown()

            // Set new callbacks for the new overlay
            this.onSurfaceReady = onSurfaceReady
            this.onSurfaceDestroyed = onSurfaceDestroyed

            createOverlay(gen, displayId, x, y, width, height, rotation, showBorder)
        }
    }

    fun hide() {
        mainHandler.post {
            generation++
            tearDown()
        }
    }

    fun isShowing(): Boolean = showing

    private fun createOverlay(gen: Int, displayId: Int, x: Int, y: Int, width: Int, height: Int, rotation: Int, showBorder: Boolean) {
        val displayManager = appContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display = displayManager.getDisplay(displayId)
        if (display == null) {
            V2AppLog.w(TAG, "secondary display not found id=$displayId")
            clearState()
            return
        }

        val displayContext = appContext.createDisplayContext(display)
        val wm = displayContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

        // Get display real size for coordinate transformation
        @Suppress("DEPRECATION")
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display.getRealMetrics(metrics)
        val displayWidth = metrics.widthPixels
        val displayHeight = metrics.heightPixels

        // Transform XY coordinates based on display rotation
        val adjustedX: Int
        val adjustedY: Int
        when (rotation) {
            180 -> {
                adjustedX = displayWidth - x - width
                adjustedY = displayHeight - y - height
            }
            else -> {
                adjustedX = x
                adjustedY = y
            }
        }

        val container = FrameLayout(displayContext)
        // Rotation is handled at the native GL level, not via View.rotation
        val sv = SurfaceView(displayContext)
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                if (gen != generation) return
                val surface = holder.surface
                if (surface.isValid) {
                    V2AppLog.i(TAG, "secondary display surface created")
                    onSurfaceReady?.invoke(surface)
                }
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {
                V2AppLog.d(TAG, "secondary display surface changed ${w}x$h format=$format")
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (gen != generation) return
                V2AppLog.i(TAG, "secondary display surface destroyed")
                onSurfaceDestroyed?.invoke()
            }
        })
        if (showBorder) {
            val border = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(4, Color.WHITE)
            }
            container.background = border
        }
        container.addView(sv, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER,
        ))

        val params = WindowManager.LayoutParams(
            width,
            height,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = adjustedX
            this.y = adjustedY
        }

        runCatching { wm.addView(container, params) }.onFailure {
            V2AppLog.w(TAG, "failed to add secondary display overlay", it)
            clearState()
            return
        }

        windowManager = wm
        rootView = container
        showing = true
        V2AppLog.i(TAG, "secondary display overlay shown id=$displayId ${width}x$height at $adjustedX,$adjustedY (user=$x,$y) rotation=$rotation display=${displayWidth}x$displayHeight border=$showBorder")
    }

    private fun tearDown() {
        val wm = windowManager
        val view = rootView
        val destroyCallback = onSurfaceDestroyed
        clearState()
        if (wm == null || view == null) return

        // Detach native preview for the old surface before the view is removed.
        destroyCallback?.invoke()
        runCatching { wm.removeViewImmediate(view) }.onFailure {
            V2AppLog.w(TAG, "failed to remove secondary display overlay", it)
        }
        V2AppLog.i(TAG, "secondary display overlay hidden")
    }

    private fun clearState() {
        rootView = null
        windowManager = null
        onSurfaceReady = null
        onSurfaceDestroyed = null
        showing = false
    }

    private companion object {
        private const val TAG = "V2BlindSpotSecondary"
    }
}
