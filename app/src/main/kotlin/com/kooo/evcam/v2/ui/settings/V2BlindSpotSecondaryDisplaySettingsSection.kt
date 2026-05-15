package com.kooo.evcam.v2.ui.settings

import android.app.AlertDialog
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Size
import android.view.Display
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
import com.kooo.evcam.v2.service.commands.V2CameraServiceCommands
import com.kooo.evcam.v2.settings.V2BlindSpotSettings
import com.kooo.evcam.v2.settings.V2SettingsCategory

internal class V2BlindSpotSecondaryDisplaySettingsSection(
    private val activity: V2SettingsActivity,
    private val cards: V2SettingsCardFactory,
) {
    private var displaySize = Size(1920, 1080)
    private var paramsContainer: LinearLayout? = null
    private val debounceHandler = Handler(Looper.getMainLooper())
    private val debounceToken = Any()

    fun create(visible: Boolean): View {
        val card = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(12), 0, 0)
            visibility = if (visible) View.VISIBLE else View.GONE
        }
        card.addView(cards.cardTexts(
            title = "副屏补盲",
            subtitle = "补盲触发时在副屏指定位置同步显示补盲画面",
            useWeight = false,
        ))

        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            visibility = if (V2BlindSpotSettings.isSecondaryDisplayEnabled(activity)) View.VISIBLE else View.GONE
        }
        paramsContainer = container

        card.addView(enableRow(container))
        rebuildParams(container)
        card.addView(container)
        return card
    }

    private fun enableRow(paramsContainer: View): View {
        val row = cards.switchRow()
        row.addView(TextView(activity).apply {
            text = "启用副屏补盲"
            textSize = 16f
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val switch = cards.settingSwitch(V2BlindSpotSettings.isSecondaryDisplayEnabled(activity)) { enabled ->
            V2BlindSpotSettings.setSecondaryDisplayEnabled(activity, enabled)
            paramsContainer.visibility = if (enabled) View.VISIBLE else View.GONE
            V2CameraServiceCommands.notifySettingsChanged(activity, V2SettingsCategory.BLIND_SPOT)
        }
        row.addView(switch)
        return row
    }

    private fun rebuildParams(container: LinearLayout) {
        container.removeAllViews()

        val savedDisplayId = V2BlindSpotSettings.secondaryDisplayId(activity)
        updateDisplaySize(savedDisplayId)

        container.addView(displayIdRow(container))
        container.addView(rotationRow())
        container.addView(sliderRow("位置 X", 0, displaySize.width, V2BlindSpotSettings.secondaryDisplayX(activity)) { value ->
            saveBounds(x = value)
        })
        container.addView(sliderRow("位置 Y", 0, displaySize.height, V2BlindSpotSettings.secondaryDisplayY(activity)) { value ->
            saveBounds(y = value)
        })
        container.addView(sliderRow("宽度", 1, displaySize.width, V2BlindSpotSettings.secondaryDisplayWidth(activity)) { value ->
            saveBounds(width = value)
        })
        container.addView(sliderRow("高度", 1, displaySize.height, V2BlindSpotSettings.secondaryDisplayHeight(activity)) { value ->
            saveBounds(height = value)
        })
        container.addView(borderRow())
        container.addView(previewButton())
    }

    private fun displayIdRow(container: LinearLayout): View {
        val displays = detectDisplays()
        val savedId = V2BlindSpotSettings.secondaryDisplayId(activity)
        val labels = displays.map { it.label }
        val selectedIndex = displays.indexOfFirst { it.id == savedId }.coerceAtLeast(0)

        if (displays.isNotEmpty() && savedId < 0) {
            val firstId = displays[0].id
            V2BlindSpotSettings.setSecondaryDisplayId(activity, firstId)
            updateDisplaySize(firstId)
        }

        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        row.addView(TextView(activity).apply {
            text = "副屏"
            textSize = 16f
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        if (labels.isEmpty()) {
            row.addView(TextView(activity).apply {
                text = "未检测到副屏"
                textSize = 16f
                setTextColor(ContextCompat.getColor(activity, R.color.text_secondary))
            })
        } else {
            val dropdown = cards.dropdownField(
                labels = labels,
                selectedIndex = selectedIndex,
                onSelected = { position ->
                    val selected = displays[position]
                    V2BlindSpotSettings.setSecondaryDisplayId(activity, selected.id)
                    updateDisplaySize(selected.id)
                    rebuildParams(container)
                    notifyChanged()
                },
                widthDp = 280,
            )
            row.addView(dropdown, LinearLayout.LayoutParams(dp(280), ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        return row
    }

    private fun rotationRow(): View {
        val labels = listOf("0°", "90°", "180°", "270°")
        val values = listOf(0, 90, 180, 270)
        val current = V2BlindSpotSettings.secondaryDisplayRotation(activity)
        val selected = values.indexOf(current).coerceAtLeast(0)

        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        row.addView(TextView(activity).apply {
            text = "旋转角度"
            textSize = 16f
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        val dropdown = cards.dropdownField(
            labels = labels,
            selectedIndex = selected,
            onSelected = { position ->
                V2BlindSpotSettings.setSecondaryDisplayRotation(activity, values[position])
                notifyChanged()
            },
            widthDp = 160,
        )
        row.addView(dropdown, LinearLayout.LayoutParams(dp(160), ViewGroup.LayoutParams.WRAP_CONTENT))
        return row
    }

    private fun sliderRow(label: String, min: Int, max: Int, value: Int, onChanged: (Int) -> Unit): View {
        val clampedMax = max.coerceAtLeast(min + 1)
        val clampedValue = value.coerceIn(min, clampedMax)
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(6), 0, dp(6))
        }
        val valueLabel = TextView(activity).apply {
            text = "$label  $clampedValue"
            textSize = 16f
            includeFontPadding = false
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
        }
        val seekBar = cards.styleSlider(SeekBar(activity).apply {
            this.max = clampedMax - min
            progress = clampedValue - min
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    val current = progress + min
                    valueLabel.text = "$label  $current"
                }
                override fun onStartTrackingTouch(seekBar: SeekBar) {}
                override fun onStopTrackingTouch(seekBar: SeekBar) {
                    val current = seekBar.progress + min
                    onChanged(current)
                }
            })
        })
        valueLabel.setOnClickListener {
            val input = EditText(activity).apply {
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_SIGNED
                setText((seekBar.progress + min).toString())
                selectAll()
            }
            AlertDialog.Builder(activity)
                .setTitle(label)
                .setView(input)
                .setPositiveButton("确定") { _, _ ->
                    val v = input.text.toString().toIntOrNull() ?: return@setPositiveButton
                    val clamped = v.coerceIn(min, clampedMax)
                    seekBar.progress = clamped - min
                    valueLabel.text = "$label  $clamped"
                    onChanged(clamped)
                }
                .setNegativeButton("取消", null)
                .show()
        }
        row.addView(valueLabel, LinearLayout.LayoutParams(dp(110), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            marginEnd = dp(10)
        })
        row.addView(seekBar, LinearLayout.LayoutParams(0, dp(40), 1f))
        return row
    }

    private fun borderRow(): View {
        val row = cards.switchRow()
        row.addView(TextView(activity).apply {
            text = "白色边框"
            textSize = 16f
            setTextColor(ContextCompat.getColor(activity, R.color.text_primary))
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val switch = cards.settingSwitch(V2BlindSpotSettings.isSecondaryDisplayBorderEnabled(activity)) { enabled ->
            V2BlindSpotSettings.setSecondaryDisplayBorderEnabled(activity, enabled)
            notifyChanged()
        }
        row.addView(switch)
        return row
    }

    private fun previewButton(): View = cards.actionButton("预览副屏补盲", {
        V2CameraServiceCommands.showBlindSpotPreview(activity, "left")
        Toast.makeText(activity, "已触发补盲预览", Toast.LENGTH_SHORT).show()
    }, minWidthDp = 220, minHeightDp = 80).apply {
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(80)).apply {
            setMargins(0, dp(8), 0, dp(8))
        }
    }

    private data class DisplayInfo(val id: Int, val label: String, val width: Int, val height: Int)

    private fun detectDisplays(): List<DisplayInfo> {
        val dm = activity.getSystemService(DisplayManager::class.java) ?: return emptyList()
        return dm.displays
            .filter { it.displayId != Display.DEFAULT_DISPLAY }
            .map { display ->
                val size = displayRealSize(display)
                DisplayInfo(
                    id = display.displayId,
                    label = "Display ${display.displayId}  (${size.width}×${size.height})",
                    width = size.width,
                    height = size.height,
                )
            }
    }

    private fun updateDisplaySize(displayId: Int) {
        val dm = activity.getSystemService(DisplayManager::class.java) ?: return
        val display = dm.getDisplay(displayId) ?: return
        displaySize = displayRealSize(display)
    }

    @Suppress("DEPRECATION")
    private fun displayRealSize(display: Display): Size {
        val metrics = android.util.DisplayMetrics()
        display.getRealMetrics(metrics)
        return Size(metrics.widthPixels, metrics.heightPixels)
    }

    private fun saveBounds(
        x: Int = V2BlindSpotSettings.secondaryDisplayX(activity),
        y: Int = V2BlindSpotSettings.secondaryDisplayY(activity),
        width: Int = V2BlindSpotSettings.secondaryDisplayWidth(activity),
        height: Int = V2BlindSpotSettings.secondaryDisplayHeight(activity),
    ) {
        V2BlindSpotSettings.setSecondaryDisplayBounds(activity, x, y, width, height)
        notifyChanged()
    }

    private fun notifyChanged() {
        debounceHandler.removeCallbacksAndMessages(debounceToken)
        debounceHandler.postDelayed({
            V2CameraServiceCommands.notifySettingsChanged(activity, V2SettingsCategory.BLIND_SPOT)
        }, debounceToken, NOTIFY_DEBOUNCE_MS)
    }

    private fun dp(value: Int): Int = cards.dp(value)

    private companion object {
        private const val NOTIFY_DEBOUNCE_MS = 300L
    }
}
