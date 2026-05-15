package com.kooo.evcam.v2.settings

import android.content.Context
import com.kooo.evcam.v2.service.V2_CAMERA_SLOT_COUNT

object V2SettingsRepository {
    fun currentSnapshot(context: Context): V2SettingsSnapshot {
        val app = context.applicationContext
        return V2SettingsSnapshot(
            vehicle = vehicleConfig(app),
            recording = recordingConfig(app),
            fisheye = fisheyeConfig(app),
            avoidance = avoidanceConfig(app),
            blindSpot = blindSpotConfig(app),
            customKey = customKeyConfig(app),
            startup = startupPolicy(app),
            keepAlive = keepAlivePolicy(app),
        )
    }

    fun vehicleConfig(context: Context): V2SettingsSnapshot.Vehicle {
        val model = V2VehicleModelSettings.getModel(context)
        return V2SettingsSnapshot.Vehicle(
            id = model.id,
            label = model.label,
            mapping = V2SettingsSnapshot.CameraMapping(
                front = model.mapping.front,
                back = model.mapping.back,
                left = model.mapping.left,
                right = model.mapping.right,
            ),
            useMainBranchFourCameraFallback = model.id == V2VehicleModelSettings.MODEL_XINGHAN_7_2026,
        )
    }

    fun recordingConfig(context: Context) = V2SettingsSnapshot.Recording(
        resolution = V2RecordingSettings.resolution(context),
        bitrateLevel = V2RecordingSettings.bitrateLevel(context),
        fps = V2RecordingSettings.fps(context),
        segmentMinutes = V2RecordingSettings.segmentMinutes(context),
    )

    fun fisheyeConfig(context: Context) = V2SettingsSnapshot.Fisheye(
        enabled = V2FisheyeSettings.isEnabled(context),
        params = List(V2_CAMERA_SLOT_COUNT) { V2FisheyeSettings.paramsForIndex(context, it) },
        blindSpotEnabled = V2FisheyeSettings.isBlindSpotEnabled(context),
        blindSpotParams = List(V2_CAMERA_SLOT_COUNT) { V2FisheyeSettings.blindSpotParamsForIndex(context, it) },
    )

    fun avoidanceConfig(context: Context) = V2SettingsSnapshot.Avoidance(
        behaviorMask = V2AvoidanceSettings.behaviorMask(context),
        targets = V2AvoidanceSettings.targetValues(context),
    )

    fun blindSpotConfig(context: Context) = V2SettingsSnapshot.BlindSpot(
        enabled = V2BlindSpotSettings.isEnabled(context),
        turnSignalPropId = V2BlindSpotSettings.turnSignalPropId(context),
        correctionEnabled = V2BlindSpotSettings.isCorrectionEnabled(context),
        windowMode = V2BlindSpotSettings.windowMode(context),
        hideDelayMs = V2BlindSpotSettings.hideDelaySeconds(context) * 1_000L,
        secondaryDisplay = V2SettingsSnapshot.SecondaryDisplay(
            enabled = V2BlindSpotSettings.isSecondaryDisplayEnabled(context),
            displayId = V2BlindSpotSettings.secondaryDisplayId(context),
            rotation = V2BlindSpotSettings.secondaryDisplayRotation(context),
            x = V2BlindSpotSettings.secondaryDisplayX(context),
            y = V2BlindSpotSettings.secondaryDisplayY(context),
            width = V2BlindSpotSettings.secondaryDisplayWidth(context),
            height = V2BlindSpotSettings.secondaryDisplayHeight(context),
            showBorder = V2BlindSpotSettings.isSecondaryDisplayBorderEnabled(context),
        ),
    )

    fun blindSpotOverlayConfig(
        context: Context,
        side: String,
        defaultX: Int,
        defaultY: Int,
        defaultWidth: Int,
        defaultHeight: Int,
    ): V2SettingsSnapshot.BlindSpotOverlay {
        val app = context.applicationContext
        val correctionEnabled = V2BlindSpotSettings.isCorrectionEnabled(app)
        return V2SettingsSnapshot.BlindSpotOverlay(
            side = side,
            x = V2BlindSpotSettings.overlayX(app, side, defaultX),
            y = V2BlindSpotSettings.overlayY(app, side, defaultY),
            width = V2BlindSpotSettings.overlayWidth(app, side, defaultWidth),
            height = V2BlindSpotSettings.overlayHeight(app, side, defaultHeight),
            correction = if (correctionEnabled) V2BlindSpotSettings.correction(app, side) else V2BlindSpotCorrection(),
        )
    }

    fun customKeyConfig(context: Context) = V2SettingsSnapshot.CustomKey(
        enabled = V2CustomKeySettings.isEnabled(context),
        buttonPropId = V2CustomKeySettings.buttonPropId(context),
    )

    fun startupPolicy(context: Context) = V2SettingsSnapshot.Startup(
        autoStartOnBoot = V2StartupSettings.isAutoStartOnBoot(context),
        autoStartRecording = V2StartupSettings.isAutoStartRecording(context),
    )

    fun keepAlivePolicy(context: Context) = V2SettingsSnapshot.KeepAlive(
        enabled = V2KeepAliveSettings.isKeepAliveEnabled(context),
        preventSleep = V2KeepAliveSettings.isPreventSleepEnabled(context),
    )
}
