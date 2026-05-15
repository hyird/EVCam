package com.kooo.evcam.v2.settings

data class V2SettingsSnapshot(
    val vehicle: Vehicle,
    val recording: Recording,
    val fisheye: Fisheye,
    val avoidance: Avoidance,
    val blindSpot: BlindSpot,
    val customKey: CustomKey,
    val startup: Startup,
    val keepAlive: KeepAlive,
) {
    data class CameraMapping(
        val front: String,
        val back: String,
        val left: String,
        val right: String,
    )

    data class Vehicle(
        val id: String,
        val label: String,
        val mapping: CameraMapping,
        val useMainBranchFourCameraFallback: Boolean,
    )

    data class Recording(
        val resolution: String,
        val bitrateLevel: String,
        val fps: Int,
        val segmentMinutes: Int,
    )

    data class Fisheye(
        val enabled: Boolean,
        val params: List<V2FisheyeParams>,
        val blindSpotEnabled: Boolean,
        val blindSpotParams: List<V2FisheyeParams>,
    ) {
        fun paramsForIndex(index: Int): V2FisheyeParams =
            params.getOrElse(index) { V2FisheyeParams.defaultForIndex(index) }

        fun blindSpotParamsForIndex(index: Int): V2FisheyeParams =
            blindSpotParams.getOrElse(index) { V2FisheyeParams.defaultForIndex(index) }
    }

    data class Avoidance(
        val behaviorMask: Int,
        val targets: List<String>,
    ) {
        val enabled: Boolean get() = behaviorMask != 0 && targets.isNotEmpty()
        val hideBlindSpot: Boolean get() = behaviorMask and V2AvoidanceBehaviors.HIDE_BLIND_SPOT != 0
        val exitForeground: Boolean get() = behaviorMask and V2AvoidanceBehaviors.EXIT_FOREGROUND != 0
        val stopRecording: Boolean get() = behaviorMask and V2AvoidanceBehaviors.STOP_RECORDING != 0
        fun behaviorLabels(): String = V2AvoidanceBehaviors.labels(behaviorMask)
    }

    data class BlindSpot(
        val enabled: Boolean,
        val turnSignalPropId: Int,
        val correctionEnabled: Boolean,
        val windowMode: String,
        val leftValue: Int = 1,
        val rightValue: Int = 2,
        val offValue: Int = 0,
        val hideDelayMs: Long = 1_000L,
        val secondaryDisplay: SecondaryDisplay = SecondaryDisplay(),
    )

    data class SecondaryDisplay(
        val enabled: Boolean = false,
        val displayId: Int = -1,
        val rotation: Int = 0,
        val x: Int = 0,
        val y: Int = 0,
        val width: Int = 400,
        val height: Int = 300,
        val showBorder: Boolean = false,
    )

    data class BlindSpotOverlay(
        val side: String,
        val x: Int,
        val y: Int,
        val width: Int,
        val height: Int,
        val correction: V2BlindSpotCorrection,
    )

    data class CustomKey(
        val enabled: Boolean,
        val buttonPropId: Int,
    )

    data class Startup(
        val autoStartOnBoot: Boolean,
        val autoStartRecording: Boolean,
    )

    data class KeepAlive(
        val enabled: Boolean,
        val preventSleep: Boolean,
    )
}
