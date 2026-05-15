package com.kooo.evcam.v2.settings

import android.content.Context
import com.kooo.evcam.v2.log.V2AppLog

object V2BlindSpotSettings {
    private const val PREFS = "evcam_v2_blind_spot_settings"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_TURN_SIGNAL_PROP_ID = "turn_signal_prop_id"
    private const val KEY_OVERLAY_X = "overlay_x"
    private const val KEY_OVERLAY_Y = "overlay_y"
    private const val KEY_OVERLAY_WIDTH = "overlay_width"
    private const val KEY_OVERLAY_HEIGHT = "overlay_height"
    private const val KEY_OVERLAY_PREFIX = "overlay_"
    private const val KEY_CORRECTION_ENABLED = "blind_spot_correction_enabled"
    private const val KEY_WINDOW_MODE = "window_mode"
    private const val KEY_WINDOW_ORIENTATION = "window_orientation"
    private const val KEY_SECONDARY_DISPLAY_ENABLED = "secondary_display_enabled"
    private const val KEY_SECONDARY_DISPLAY_ID = "secondary_display_id"
    private const val KEY_SECONDARY_DISPLAY_ROTATION = "secondary_display_rotation"
    private const val KEY_SECONDARY_DISPLAY_X = "secondary_display_x"
    private const val KEY_SECONDARY_DISPLAY_Y = "secondary_display_y"
    private const val KEY_SECONDARY_DISPLAY_WIDTH = "secondary_display_width"
    private const val KEY_SECONDARY_DISPLAY_HEIGHT = "secondary_display_height"
    private const val KEY_SECONDARY_DISPLAY_BORDER = "secondary_display_border"
    private const val KEY_HIDE_DELAY_SECONDS = "hide_delay_seconds"

    const val DEFAULT_TURN_SIGNAL_PROP_ID = 557875254
    private const val LEGACY_DEFAULT_TURN_SIGNAL_PROP_ID = 289408008
    const val WINDOW_MODE_SYSTEM_SMALL_WINDOW = "system_small_window"
    const val WINDOW_MODE_FLOATING_OVERLAY = "floating_overlay"
    const val DEFAULT_WINDOW_MODE = WINDOW_MODE_SYSTEM_SMALL_WINDOW
    const val LEFT_VALUE = 1
    const val RIGHT_VALUE = 2
    const val OFF_VALUE = 0
    const val HIDE_DELAY_MS = 1_000L
    const val DEFAULT_HIDE_DELAY_SECONDS = 1
    const val MIN_HIDE_DELAY_SECONDS = 1
    const val MAX_HIDE_DELAY_SECONDS = 20
    const val MIN_CORRECTION_SCALE = 0.05f
    const val MAX_CORRECTION_SCALE = 6.0f
    const val MIN_CORRECTION_TRANSLATE = -6.0f
    const val MAX_CORRECTION_TRANSLATE = 6.0f
    const val MIN_CORRECTION_ROTATION = -360.0f
    const val MAX_CORRECTION_ROTATION = 360.0f

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
        V2AppLog.i("V2BlindSpotSettings", "enabled=$enabled")
    }

    fun turnSignalPropId(context: Context): Int {
        val prefs = prefs(context)
        val propId = prefs.getInt(KEY_TURN_SIGNAL_PROP_ID, DEFAULT_TURN_SIGNAL_PROP_ID)
        if (propId == LEGACY_DEFAULT_TURN_SIGNAL_PROP_ID) {
            prefs.edit().putInt(KEY_TURN_SIGNAL_PROP_ID, DEFAULT_TURN_SIGNAL_PROP_ID).apply()
            V2AppLog.i("V2BlindSpotSettings", "migrate turnSignalPropId=$DEFAULT_TURN_SIGNAL_PROP_ID")
            return DEFAULT_TURN_SIGNAL_PROP_ID
        }
        return propId
    }

    fun setTurnSignalPropId(context: Context, propId: Int) {
        prefs(context).edit().putInt(KEY_TURN_SIGNAL_PROP_ID, propId).apply()
        V2AppLog.i("V2BlindSpotSettings", "turnSignalPropId=$propId")
    }

    fun overlayX(context: Context, defaultValue: Int): Int = prefs(context).getInt(KEY_OVERLAY_X, defaultValue)

    fun overlayY(context: Context, defaultValue: Int): Int = prefs(context).getInt(KEY_OVERLAY_Y, defaultValue)

    fun overlayWidth(context: Context, defaultValue: Int): Int = prefs(context).getInt(KEY_OVERLAY_WIDTH, defaultValue)

    fun overlayHeight(context: Context, defaultValue: Int): Int = prefs(context).getInt(KEY_OVERLAY_HEIGHT, defaultValue)

    fun overlayX(context: Context, side: String, defaultValue: Int): Int =
        prefs(context).getInt(overlayKey(side, "x"), overlayX(context, defaultValue))

    fun overlayY(context: Context, side: String, defaultValue: Int): Int =
        prefs(context).getInt(overlayKey(side, "y"), overlayY(context, defaultValue))

    fun overlayWidth(context: Context, side: String, defaultValue: Int): Int =
        prefs(context).getInt(overlayKey(side, "width"), overlayWidth(context, defaultValue))

    fun overlayHeight(context: Context, side: String, defaultValue: Int): Int =
        prefs(context).getInt(overlayKey(side, "height"), overlayHeight(context, defaultValue))

    fun windowMode(context: Context): String {
        val value = prefs(context).getString(KEY_WINDOW_MODE, DEFAULT_WINDOW_MODE)
        return normalizeWindowMode(value)
    }

    fun setWindowMode(context: Context, mode: String) {
        val normalized = normalizeWindowMode(mode)
        prefs(context).edit().putString(KEY_WINDOW_MODE, normalized).apply()
        V2AppLog.i("V2BlindSpotSettings", "windowMode=$normalized")
    }

    val DEFAULT_CORRECTION = V2BlindSpotCorrection()

    fun isCorrectionEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_CORRECTION_ENABLED, false)

    fun setCorrectionEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_CORRECTION_ENABLED, enabled).apply()
        V2AppLog.i("V2BlindSpotSettings", "correctionEnabled=$enabled")
    }

    fun correction(context: Context, side: String): V2BlindSpotCorrection = V2BlindSpotCorrection(
        scaleX = prefs(context).getFloat(correctionKey(side, "scale_x"), 1f)
            .coerceIn(MIN_CORRECTION_SCALE, MAX_CORRECTION_SCALE),
        scaleY = prefs(context).getFloat(correctionKey(side, "scale_y"), 1f)
            .coerceIn(MIN_CORRECTION_SCALE, MAX_CORRECTION_SCALE),
        translateX = prefs(context).getFloat(correctionKey(side, "translate_x"), 0f)
            .coerceIn(MIN_CORRECTION_TRANSLATE, MAX_CORRECTION_TRANSLATE),
        translateY = prefs(context).getFloat(correctionKey(side, "translate_y"), 0f)
            .coerceIn(MIN_CORRECTION_TRANSLATE, MAX_CORRECTION_TRANSLATE),
        rotation = normalizeCorrectionRotation(prefs(context).getFloat(correctionKey(side, "rotation"), 0f)),
        mirrorH = prefs(context).getBoolean(correctionKey(side, "mirror_h"), false),
        mirrorV = prefs(context).getBoolean(correctionKey(side, "mirror_v"), false),
    )

    fun setOverlayPosition(context: Context, x: Int, y: Int) {
        prefs(context).edit().putInt(KEY_OVERLAY_X, x).putInt(KEY_OVERLAY_Y, y).apply()
        V2AppLog.i("V2BlindSpotSettings", "overlayPosition=$x,$y")
    }

    fun setOverlayBounds(context: Context, x: Int, y: Int, width: Int, height: Int) {
        prefs(context).edit()
            .putInt(KEY_OVERLAY_X, x)
            .putInt(KEY_OVERLAY_Y, y)
            .putInt(KEY_OVERLAY_WIDTH, width)
            .putInt(KEY_OVERLAY_HEIGHT, height)
            .apply()
        V2AppLog.i("V2BlindSpotSettings", "overlayBounds=$x,$y ${width}x$height")
    }

    fun setOverlayBounds(context: Context, side: String, x: Int, y: Int, width: Int, height: Int) {
        prefs(context).edit()
            .putInt(overlayKey(side, "x"), x)
            .putInt(overlayKey(side, "y"), y)
            .putInt(overlayKey(side, "width"), width)
            .putInt(overlayKey(side, "height"), height)
            .apply()
        V2AppLog.i("V2BlindSpotSettings", "overlayBounds side=$side $x,$y ${width}x$height")
    }

    fun setCorrection(context: Context, side: String, correction: V2BlindSpotCorrection) {
        prefs(context).edit()
            .putFloat(
                correctionKey(side, "scale_x"),
                correction.scaleX.coerceIn(MIN_CORRECTION_SCALE, MAX_CORRECTION_SCALE),
            )
            .putFloat(
                correctionKey(side, "scale_y"),
                correction.scaleY.coerceIn(MIN_CORRECTION_SCALE, MAX_CORRECTION_SCALE),
            )
            .putFloat(
                correctionKey(side, "translate_x"),
                correction.translateX.coerceIn(MIN_CORRECTION_TRANSLATE, MAX_CORRECTION_TRANSLATE),
            )
            .putFloat(
                correctionKey(side, "translate_y"),
                correction.translateY.coerceIn(MIN_CORRECTION_TRANSLATE, MAX_CORRECTION_TRANSLATE),
            )
            .putFloat(correctionKey(side, "rotation"), normalizeCorrectionRotation(correction.rotation))
            .putBoolean(correctionKey(side, "mirror_h"), correction.mirrorH)
            .putBoolean(correctionKey(side, "mirror_v"), correction.mirrorV)
            .apply()
        V2AppLog.i("V2BlindSpotSettings", "correction side=$side value=$correction")
    }

    fun resetCorrection(context: Context, side: String) {
        setCorrection(context, side, DEFAULT_CORRECTION)
    }

    fun resetAllCorrections(context: Context) {
        resetCorrection(context, "left")
        resetCorrection(context, "right")
        V2AppLog.i("V2BlindSpotSettings", "reset all correction params")
    }

    fun hideDelaySeconds(context: Context): Int =
        prefs(context).getInt(KEY_HIDE_DELAY_SECONDS, DEFAULT_HIDE_DELAY_SECONDS)
            .coerceIn(MIN_HIDE_DELAY_SECONDS, MAX_HIDE_DELAY_SECONDS)

    fun setHideDelaySeconds(context: Context, seconds: Int) {
        val clamped = seconds.coerceIn(MIN_HIDE_DELAY_SECONDS, MAX_HIDE_DELAY_SECONDS)
        prefs(context).edit().putInt(KEY_HIDE_DELAY_SECONDS, clamped).apply()
        V2AppLog.i("V2BlindSpotSettings", "hideDelaySeconds=$clamped")
    }

    fun isSecondaryDisplayEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_SECONDARY_DISPLAY_ENABLED, false)

    fun setSecondaryDisplayEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_SECONDARY_DISPLAY_ENABLED, enabled).apply()
        V2AppLog.i("V2BlindSpotSettings", "secondaryDisplayEnabled=$enabled")
    }

    fun secondaryDisplayId(context: Context): Int = prefs(context).getInt(KEY_SECONDARY_DISPLAY_ID, -1)

    fun setSecondaryDisplayId(context: Context, id: Int) {
        prefs(context).edit().putInt(KEY_SECONDARY_DISPLAY_ID, id).apply()
        V2AppLog.i("V2BlindSpotSettings", "secondaryDisplayId=$id")
    }

    fun secondaryDisplayRotation(context: Context): Int = prefs(context).getInt(KEY_SECONDARY_DISPLAY_ROTATION, 0)

    fun setSecondaryDisplayRotation(context: Context, rotation: Int) {
        val normalized = ((rotation % 360) + 360) % 360
        prefs(context).edit().putInt(KEY_SECONDARY_DISPLAY_ROTATION, normalized).apply()
        V2AppLog.i("V2BlindSpotSettings", "secondaryDisplayRotation=$normalized")
    }

    fun secondaryDisplayX(context: Context): Int = prefs(context).getInt(KEY_SECONDARY_DISPLAY_X, 0)

    fun secondaryDisplayY(context: Context): Int = prefs(context).getInt(KEY_SECONDARY_DISPLAY_Y, 0)

    fun secondaryDisplayWidth(context: Context): Int = prefs(context).getInt(KEY_SECONDARY_DISPLAY_WIDTH, 400)

    fun secondaryDisplayHeight(context: Context): Int = prefs(context).getInt(KEY_SECONDARY_DISPLAY_HEIGHT, 300)

    fun setSecondaryDisplayBounds(context: Context, x: Int, y: Int, width: Int, height: Int) {
        prefs(context).edit()
            .putInt(KEY_SECONDARY_DISPLAY_X, x)
            .putInt(KEY_SECONDARY_DISPLAY_Y, y)
            .putInt(KEY_SECONDARY_DISPLAY_WIDTH, width)
            .putInt(KEY_SECONDARY_DISPLAY_HEIGHT, height)
            .apply()
        V2AppLog.i("V2BlindSpotSettings", "secondaryDisplayBounds=$x,$y ${width}x$height")
    }

    fun isSecondaryDisplayBorderEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_SECONDARY_DISPLAY_BORDER, false)

    fun setSecondaryDisplayBorderEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_SECONDARY_DISPLAY_BORDER, enabled).apply()
        V2AppLog.i("V2BlindSpotSettings", "secondaryDisplayBorder=$enabled")
    }

    fun normalizeCorrectionRotation(rotation: Float): Float {
        if (rotation in MIN_CORRECTION_ROTATION..MAX_CORRECTION_ROTATION) return rotation
        val normalized = ((rotation % 360f) + 360f) % 360f
        return if (normalized > MAX_CORRECTION_ROTATION) normalized - 360f else normalized
    }

    private fun overlayKey(side: String, name: String): String =
        KEY_OVERLAY_PREFIX + if (side == "right") "right_$name" else "left_$name"

    private fun correctionKey(side: String, name: String): String = "blind_spot_correction_${side}_$name"

    private fun normalizeWindowMode(mode: String?): String =
        if (mode == WINDOW_MODE_FLOATING_OVERLAY) WINDOW_MODE_FLOATING_OVERLAY else WINDOW_MODE_SYSTEM_SMALL_WINDOW

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
