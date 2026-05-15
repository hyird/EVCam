package com.kooo.evcam.v2.ui.settings

import android.app.AlertDialog
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.kooo.evcam.R
import com.kooo.evcam.v2.log.V2AppLog
import com.kooo.evcam.v2.service.commands.V2CameraServiceCommands
import com.kooo.evcam.v2.settings.V2BlindSpotSettings
import com.kooo.evcam.v2.settings.V2CustomKeySettings
import com.kooo.evcam.v2.settings.V2SettingsCategory

class V2SignalSettingsSection(
    private val activity: V2SettingsActivity,
    private val cards: V2SettingsCardFactory,
) {
    private val blindSpotFisheye = V2FisheyeSettingsSection(activity, cards)
    private val blindSpotCorrection = V2BlindSpotCorrectionSettingsSection(activity, cards)
    private val secondaryDisplay = V2BlindSpotSecondaryDisplaySettingsSection(activity, cards)

    fun blindSpotCard(): View {
        val hideSeconds = V2BlindSpotSettings.hideDelaySeconds(activity)
        val card = propIdSwitchCard(
            title = "转向补盲",
            subtitle = "监听 VHAL 转向灯属性；左=${V2BlindSpotSettings.LEFT_VALUE} 右=${V2BlindSpotSettings.RIGHT_VALUE} 关=${V2BlindSpotSettings.OFF_VALUE}；归零稳定 $hideSeconds 秒后关闭补盲窗口",
            propId = V2BlindSpotSettings.turnSignalPropId(activity),
            defaultPropId = V2BlindSpotSettings.DEFAULT_TURN_SIGNAL_PROP_ID,
            checked = V2BlindSpotSettings.isEnabled(activity),
            invalidToast = "转向灯属性ID无效",
            successToast = "补盲设置已生效",
            logPrefix = "blindSpot",
            settingsCategory = V2SettingsCategory.BLIND_SPOT,
            propIdReader = { V2BlindSpotSettings.turnSignalPropId(activity) },
            propIdWriter = { V2BlindSpotSettings.setTurnSignalPropId(activity, it) },
            enabledWriter = { V2BlindSpotSettings.setEnabled(activity, it) }
        ) { enabled ->
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(hideDelayRow(enabled))
                addView(blindSpotFisheye.createBlindSpot(enabled))
                addView(blindSpotCorrection.create(enabled))
                addView(secondaryDisplay.create(enabled))
            }
        }
        return card
    }

    fun customKeyCard(): View = propIdSwitchCard(
        title = "定制键调出/隐藏",
        subtitle = "监听 VHAL 按钮属性值变为 4 时切换主界面显示状态",
        propId = V2CustomKeySettings.buttonPropId(activity),
        defaultPropId = V2CustomKeySettings.DEFAULT_BUTTON_PROP_ID,
        checked = V2CustomKeySettings.isEnabled(activity),
        invalidToast = "属性ID无效",
        successToast = "定制键设置已生效",
        logPrefix = "customKey",
        settingsCategory = V2SettingsCategory.CUSTOM_KEY,
        propIdReader = { V2CustomKeySettings.buttonPropId(activity) },
        propIdWriter = { V2CustomKeySettings.setButtonPropId(activity, it) },
        enabledWriter = { V2CustomKeySettings.setEnabled(activity, it) }
    )

    private fun propIdSwitchCard(
        title: String,
        subtitle: String,
        propId: Int,
        defaultPropId: Int,
        checked: Boolean,
        invalidToast: String,
        successToast: String,
        logPrefix: String,
        settingsCategory: String,
        propIdReader: () -> Int,
        propIdWriter: (Int) -> Unit,
        enabledWriter: (Boolean) -> Unit,
        extraContent: ((Boolean) -> View)? = null
    ): View {
        val row = cards.cardContainer()
        row.addView(cards.cardTexts(title, subtitle, useWeight = false))
        val propEdit = EditText(activity).apply {
            setText(propId.toString())
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_SIGNED
            setSingleLine(true)
            textSize = 16f
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
            setHintTextColor(ContextCompat.getColor(activity, R.color.text_secondary))
            hint = defaultPropId.toString()
            setBackgroundResource(R.drawable.v2_settings_field_bg)
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }
        val switch = cards.settingSwitch(checked) { }
        val controls = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        controls.addView(View(activity), LinearLayout.LayoutParams(0, 1, 1f))
        controls.addView(propEdit, LinearLayout.LayoutParams(dp(150), ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(12) })
        controls.addView(switch)

        fun saveAndRefresh(showToast: Boolean) {
            val inputPropId = propEdit.text?.toString()?.trim()?.toIntOrNull()
            if (inputPropId == null || inputPropId <= 0) {
                V2AppLog.w(TAG, "invalid $logPrefix propId input=${propEdit.text}")
                Toast.makeText(activity, invalidToast, Toast.LENGTH_SHORT).show()
                propEdit.setText(propIdReader().toString())
                return
            }
            propIdWriter(inputPropId)
            enabledWriter(switch.isChecked)
            V2AppLog.i(TAG, "$logPrefix enabled=${switch.isChecked} propId=$inputPropId")
            V2CameraServiceCommands.notifySettingsChanged(activity, settingsCategory)
            if (showToast) Toast.makeText(activity, successToast, Toast.LENGTH_SHORT).show()
        }

        val extraView = extraContent?.invoke(checked)
        switch.setOnClickListener {
            switch.isChecked = !switch.isChecked
            extraView?.visibility = if (switch.isChecked) View.VISIBLE else View.GONE
            saveAndRefresh(true)
        }
        propEdit.setOnEditorActionListener { _, _, _ -> saveAndRefresh(true); true }
        propEdit.setOnFocusChangeListener { _, hasFocus -> if (!hasFocus) saveAndRefresh(false) }
        row.addView(controls)
        if (extraView != null) row.addView(extraView)
        return row
    }

    private fun hideDelayRow(visible: Boolean): View {
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(12), 0, 0)
            visibility = if (visible) View.VISIBLE else View.GONE
        }
        val current = V2BlindSpotSettings.hideDelaySeconds(activity)
        val label = TextView(activity).apply {
            text = "关闭延迟：${current} 秒"
            textSize = 16f
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
        }
        container.addView(label)
        val minDelay = V2BlindSpotSettings.MIN_HIDE_DELAY_SECONDS
        val maxDelay = V2BlindSpotSettings.MAX_HIDE_DELAY_SECONDS
        val slider = SeekBar(activity).apply {
            max = maxDelay - minDelay
            progress = current - minDelay
            setPadding(0, dp(8), 0, dp(8))
        }
        cards.styleSlider(slider)
        slider.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                val seconds = progress + minDelay
                label.text = "关闭延迟：${seconds} 秒"
            }
            override fun onStartTrackingTouch(seekBar: SeekBar) {}
            override fun onStopTrackingTouch(seekBar: SeekBar) {
                val seconds = seekBar.progress + minDelay
                V2BlindSpotSettings.setHideDelaySeconds(activity, seconds)
                V2CameraServiceCommands.notifySettingsChanged(activity, V2SettingsCategory.BLIND_SPOT)
            }
        })
        label.setOnClickListener {
            val input = EditText(activity).apply {
                inputType = InputType.TYPE_CLASS_NUMBER
                setText((slider.progress + minDelay).toString())
                selectAll()
            }
            AlertDialog.Builder(activity)
                .setTitle("关闭延迟（秒）")
                .setView(input)
                .setPositiveButton("确定") { _, _ ->
                    val v = input.text.toString().toIntOrNull() ?: return@setPositiveButton
                    val clamped = v.coerceIn(minDelay, maxDelay)
                    slider.progress = clamped - minDelay
                    label.text = "关闭延迟：${clamped} 秒"
                    V2BlindSpotSettings.setHideDelaySeconds(activity, clamped)
                    V2CameraServiceCommands.notifySettingsChanged(activity, V2SettingsCategory.BLIND_SPOT)
                }
                .setNegativeButton("取消", null)
                .show()
        }
        container.addView(slider, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))
        return container
    }

    private fun dp(value: Int): Int = cards.dp(value)

    private companion object {
        const val TAG = "V2SettingsActivity"
    }
}
