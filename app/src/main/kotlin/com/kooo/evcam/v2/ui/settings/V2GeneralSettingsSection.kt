package com.kooo.evcam.v2.ui.settings

import android.graphics.Typeface
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.widget.doAfterTextChanged
import com.kooo.evcam.R
import com.kooo.evcam.v2.log.V2AppLog
import com.kooo.evcam.v2.service.keepalive.V2KeepAliveStatus
import com.kooo.evcam.v2.settings.V2StartupSettings
import com.kooo.evcam.v2.settings.V2VehicleModelSettings

class V2GeneralSettingsSection(
    private val activity: V2SettingsActivity,
    private val cards: V2SettingsCardFactory,
) {
    private val appUpdates = V2AppUpdateSettingsCoordinator(activity, cards)

    fun versionCard(): View = cards.entryCard(
        title = "版本信息",
        subtitle = "EVCam V2\n版本：${appUpdates.versionName()}\n包名：${activity.packageName}",
        buttonText = "检查 →",
        onClick = { appUpdates.checkUpdate() }
    )

    fun keepAliveStatusCard(): View {
        val row = cards.cardRow()
        val texts = cards.cardTexts("保活状态", V2KeepAliveStatus.summary(activity), 0)
        val summaryText = texts.getChildAt(1) as TextView
        row.addView(texts)
        row.addView(cards.actionButton("刷新", { summaryText.text = V2KeepAliveStatus.summary(activity) }, minWidthDp = 168, minHeightDp = 88))
        return row
    }

    fun logExportCard(): View = cards.entryCard(
        title = "保存日志",
        subtitle = "保存本次运行日志，便于排查预览、录制和车机事件问题",
        buttonText = "保存 →",
        onClick = { saveLogs() }
    )

    fun vehicleModelCard(): View {
        val models = V2VehicleModelSettings.models
        val currentIndex = models.indexOfFirst { it.id == V2VehicleModelSettings.getModelId(activity) }.coerceAtLeast(0)

        val container = cards.cardContainer()

        val row = cards.cardRow(bottomMarginDp = 0)
        val texts = cards.cardTexts(
            "车型配置",
            vehicleModelSubtitle()
        )
        val summaryText = texts.getChildAt(1) as TextView

        val customMappingPanel = buildCustomMappingPanel(summaryText)
        customMappingPanel.visibility = if (models[currentIndex].id == V2VehicleModelSettings.MODEL_CUSTOM) View.VISIBLE else View.GONE

        val dropdown = cards.dropdownField(
            labels = models.map { it.label },
            selectedIndex = currentIndex,
            onSelected = { position ->
                val selectedModel = models[position]
                V2VehicleModelSettings.setModelId(activity, selectedModel.id)
                summaryText.text = vehicleModelSubtitle()
                customMappingPanel.visibility = if (selectedModel.id == V2VehicleModelSettings.MODEL_CUSTOM) View.VISIBLE else View.GONE
                V2AppLog.i(TAG, "vehicle model changed to ${selectedModel.label} ${V2VehicleModelSettings.mappingSummary(activity).replace('\n', ' ')}")
                Toast.makeText(activity, "需重启生效", Toast.LENGTH_SHORT).show()
            },
            widthDp = 290,
        )
        row.addView(texts)
        row.addView(dropdown)
        row.setOnClickListener { dropdown.performClick() }

        container.addView(row)
        container.addView(customMappingPanel)
        return container
    }

    private fun buildCustomMappingPanel(summaryText: TextView): LinearLayout {
        val mapping = V2VehicleModelSettings.getCustomMapping(activity)
        val dp = { v: Int -> (v * activity.resources.displayMetrics.density + 0.5f).toInt() }

        val panel = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(16), 0, 0)
        }

        val labels = listOf("前" to mapping.front, "后" to mapping.back, "左" to mapping.left, "右" to mapping.right)
        val inputs = mutableListOf<EditText>()

        val grid = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        for ((label, value) in labels) {
            val item = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginEnd = dp(12)
                }
            }

            val tv = TextView(activity).apply {
                text = label
                textSize = 17f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setTextColor(ContextCompat.getColor(activity, R.color.settings_title_primary))
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    marginEnd = dp(8)
                }
            }

            val input = EditText(activity).apply {
                setText(value)
                textSize = 17f
                inputType = InputType.TYPE_CLASS_NUMBER
                gravity = Gravity.CENTER
                minWidth = dp(56)
                setPadding(dp(8), dp(8), dp(8), dp(8))
                background = ContextCompat.getDrawable(activity, R.drawable.v2_settings_field_bg)
                setTextColor(ContextCompat.getColor(activity, R.color.settings_title_primary))
                layoutParams = LinearLayout.LayoutParams(dp(64), ViewGroup.LayoutParams.WRAP_CONTENT)
            }
            inputs.add(input)

            item.addView(tv)
            item.addView(input)
            grid.addView(item)
        }

        for (input in inputs) {
            input.doAfterTextChanged {
                val newMapping = V2VehicleModelSettings.CameraMapping(
                    front = inputs[0].text.toString().ifBlank { "0" },
                    back = inputs[1].text.toString().ifBlank { "0" },
                    left = inputs[2].text.toString().ifBlank { "0" },
                    right = inputs[3].text.toString().ifBlank { "0" },
                )
                V2VehicleModelSettings.setCustomMapping(activity, newMapping)
                summaryText.text = vehicleModelSubtitle()
            }
        }

        panel.addView(grid)
        return panel
    }

    fun startupSwitchCard(): View = cards.switchCard(
        title = "开机自启动",
        subtitle = "车机开机后自动启动 EVCam V2",
        checked = V2StartupSettings.isAutoStartOnBoot(activity),
        onCheckedChange = { enabled ->
            V2StartupSettings.setAutoStartOnBoot(activity, enabled)
            V2AppLog.i(TAG, "autoStartOnBoot=$enabled")
        }
    )

    fun recordingSwitchCard(): View = cards.switchCard(
        title = "自动录制",
        subtitle = "软件启动后立即自动开始录制；开机自启动时同样生效",
        checked = V2StartupSettings.isAutoStartRecording(activity),
        onCheckedChange = { enabled ->
            V2StartupSettings.setAutoStartRecording(activity, enabled)
            V2AppLog.i(TAG, "autoStartRecording=$enabled")
        }
    )

    private fun saveLogs() {
        V2AppLog.i(TAG, "manual log export requested")
        val file = V2AppLog.exportCurrentLogs(activity)
        if (file != null) {
            Toast.makeText(activity, "日志已保存：${file.absolutePath}", Toast.LENGTH_LONG).show()
            V2AppLog.i(TAG, "manual log exported: ${file.absolutePath}")
        } else {
            Toast.makeText(activity, "暂无日志可保存", Toast.LENGTH_SHORT).show()
            V2AppLog.w(TAG, "manual log export skipped: empty buffer")
        }
    }

    private fun vehicleModelSubtitle(): String =
        V2VehicleModelSettings.mappingSummary(activity) + "\n使用当前预览布局，仅切换前后左右摄像头映射；更改后重启应用生效"

    private companion object {
        const val TAG = "V2SettingsActivity"
    }
}
