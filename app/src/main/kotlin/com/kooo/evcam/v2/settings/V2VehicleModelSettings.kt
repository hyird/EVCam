package com.kooo.evcam.v2.settings

import android.content.Context
import com.kooo.evcam.v2.log.V2AppLog

object V2VehicleModelSettings {
    const val MODEL_E5_2025 = "galaxy_e5_2025"
    const val MODEL_XINGHAN_7_2026 = "xinghan_7_2026"
    const val MODEL_A7_2025 = "galaxy_a7_2025"
    const val MODEL_CUSTOM = "custom"

    private const val PREFS_NAME = "evcam_v2_vehicle_settings"
    private const val KEY_VEHICLE_MODEL = "vehicle_model"
    private const val KEY_CUSTOM_FRONT = "custom_front"
    private const val KEY_CUSTOM_BACK = "custom_back"
    private const val KEY_CUSTOM_LEFT = "custom_left"
    private const val KEY_CUSTOM_RIGHT = "custom_right"

    private val DEFAULT_CUSTOM_MAPPING = CameraMapping(front = "0", back = "1", left = "2", right = "3")

    data class CameraMapping(val front: String, val back: String, val left: String, val right: String) {
        fun summary(): String = "前:$front 后:$back 左:$left 右:$right"
    }

    data class VehicleModel(val id: String, val label: String, val mapping: CameraMapping) {
        fun mappingSummary(): String = "$label\n${mapping.summary()}"
    }

    val presetModels = listOf(
        VehicleModel(MODEL_E5_2025, "银河E5", CameraMapping(front = "2", back = "1", left = "3", right = "0")),
        VehicleModel(MODEL_XINGHAN_7_2026, "26款星舰7", CameraMapping(front = "3", back = "2", left = "4", right = "1")),
        VehicleModel(MODEL_A7_2025, "银河A7(带智驾)", CameraMapping(front = "2", back = "1", left = "3", right = "0")),
    )

    val models: List<VehicleModel> get() = presetModels + VehicleModel(MODEL_CUSTOM, "自定义", DEFAULT_CUSTOM_MAPPING)

    fun getModelId(context: Context): String = prefs(context).getString(KEY_VEHICLE_MODEL, MODEL_A7_2025) ?: MODEL_A7_2025

    fun setModelId(context: Context, modelId: String) {
        val model = resolveModel(context, modelId)
        prefs(context).edit().putString(KEY_VEHICLE_MODEL, modelId).apply()
        V2AppLog.i("V2VehicleModelSettings", "vehicleModel=$modelId label=${model.label} mapping=${model.mapping}")
    }

    fun getModel(context: Context): VehicleModel {
        val modelId = getModelId(context)
        return resolveModel(context, modelId)
    }

    fun getCustomMapping(context: Context): CameraMapping {
        val p = prefs(context)
        return CameraMapping(
            front = p.getString(KEY_CUSTOM_FRONT, DEFAULT_CUSTOM_MAPPING.front) ?: DEFAULT_CUSTOM_MAPPING.front,
            back = p.getString(KEY_CUSTOM_BACK, DEFAULT_CUSTOM_MAPPING.back) ?: DEFAULT_CUSTOM_MAPPING.back,
            left = p.getString(KEY_CUSTOM_LEFT, DEFAULT_CUSTOM_MAPPING.left) ?: DEFAULT_CUSTOM_MAPPING.left,
            right = p.getString(KEY_CUSTOM_RIGHT, DEFAULT_CUSTOM_MAPPING.right) ?: DEFAULT_CUSTOM_MAPPING.right,
        )
    }

    fun setCustomMapping(context: Context, mapping: CameraMapping) {
        prefs(context).edit()
            .putString(KEY_CUSTOM_FRONT, mapping.front)
            .putString(KEY_CUSTOM_BACK, mapping.back)
            .putString(KEY_CUSTOM_LEFT, mapping.left)
            .putString(KEY_CUSTOM_RIGHT, mapping.right)
            .apply()
        V2AppLog.i("V2VehicleModelSettings", "customMapping=${mapping.summary()}")
    }

    fun mappingSummary(context: Context): String {
        return getModel(context).mappingSummary()
    }

    private fun resolveModel(context: Context, modelId: String): VehicleModel {
        if (modelId == MODEL_CUSTOM) {
            val mapping = getCustomMapping(context)
            return VehicleModel(MODEL_CUSTOM, "自定义", mapping)
        }
        val model = presetModels.firstOrNull { it.id == modelId }
        if (model == null) V2AppLog.w("V2VehicleModelSettings", "unknown vehicle model=$modelId, fallback=${presetModels.first().id}")
        return model ?: presetModels.first()
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
