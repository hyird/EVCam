package com.kooo.evcam.v2.service.runtime.module

import com.kooo.evcam.v2.service.runtime.V2CameraServiceRuntimeGraph
import com.kooo.evcam.v2.service.preview.V2BlindSpotController

internal object V2CameraServiceBlindSpotModule {
    fun install(graph: V2CameraServiceRuntimeGraph) {
        graph.blindSpotController = V2BlindSpotController(
            context = graph.service,
            handler = graph.mainHandler,
            isDisplayPowerOn = { graph.isDisplayPowerOn() },
            isUiVisible = { graph.uiVisibilityOrchestrator.isVisible },
            shouldAvoidWindow = { graph.avoidanceController.shouldAvoidBlindSpotWindow() },
            avoidanceTarget = { graph.avoidanceController.activeTarget ?: graph.avoidanceController.currentTarget() },
            previewIndexForSide = { side -> graph.engine.previewIndexForPosition(side) },
            previewDescription = { index -> graph.engine.previewDescription(index) },
            attachPreview = { index, surface -> graph.previewFacade.attachBlindSpotPreviewSurface(index, surface) },
            detachPreview = { index -> graph.previewFacade.detachBlindSpotPreviewSurface(index) },
            previewInputSize = { index -> graph.engine.previewInputSize(index) },
            renderedFrames = { index -> graph.engine.previewRenderedFrames(index) },
            restoreMainPreview = { index -> graph.previewFacade.restoreMainPreviewSurface(index) },
            hideFisheyePreview = { graph.fisheyePreviewController.hide() },
            hideUi = { graph.uiVisibilityOrchestrator.hideForAvoidance() },
            showToast = { graph.statusReporter.showToast(it) },
            attachSecondaryPreview = { index, surface, rotation ->
                graph.engine.attachSecondaryPreviewSurface(
                    index = index,
                    surface = surface,
                    applyFisheye = true,
                    applyNativeTransform = true,
                    useBlindSpotFisheye = true,
                    rotation = rotation,
                )
            },
            detachSecondaryPreview = { index -> graph.engine.detachSecondaryPreviewSurface(index) },
            setSecondaryPreviewCorrection = { index, correction ->
                graph.engine.setSecondaryPreviewCorrection(
                    index = index,
                    scaleX = correction.scaleX,
                    scaleY = correction.scaleY,
                    translateX = correction.translateX,
                    translateY = correction.translateY,
                    rotation = correction.rotation,
                    mirrorH = correction.mirrorH,
                    mirrorV = correction.mirrorV,
                )
            },
        )
    }
}
