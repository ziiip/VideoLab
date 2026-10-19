//
//  VideoCompositionInstruction.swift
//  VideoLab
//
//  Created by Bear on 2020/8/29.
//  Copyright © 2020 Chocolate. All rights reserved.
//

import AVFoundation

class VideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool
    var containsTweening: Bool
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID
    let hdrGraphicsGain: Float
    let hdrGraphicsReferenceWhiteHLG: Float?

    var videoRenderLayers: [VideoRenderLayer] = []

    init(videoRenderLayers: [VideoRenderLayer], timeRange: CMTimeRange,
         hdrGraphicsGain: Float = 1, hdrGraphicsReferenceWhiteHLG: Float? = nil) {
        self.timeRange = timeRange
        self.hdrGraphicsGain = hdrGraphicsGain.isFinite && hdrGraphicsGain >= 0 ? hdrGraphicsGain : 1
        if let white = hdrGraphicsReferenceWhiteHLG, white.isFinite, white > 0, white <= 1 {
            self.hdrGraphicsReferenceWhiteHLG = white
        } else {
            self.hdrGraphicsReferenceWhiteHLG = nil
        }
        enablePostProcessing = true
        containsTweening = true
        passthroughTrackID = kCMPersistentTrackID_Invalid
        
        super.init()
        
        self.videoRenderLayers = videoRenderLayers
        
        var trackIDSet: Set<CMPersistentTrackID> = []
        videoRenderLayers.forEach { videoRenderLayer in
            if let videoRenderLayerGroup = videoRenderLayer as? VideoRenderLayerGroup {
                let recursiveTrackIDs = videoRenderLayerGroup.recursiveTrackIDs()
                trackIDSet = trackIDSet.union(Set(recursiveTrackIDs))
            } else {
                trackIDSet.insert(videoRenderLayer.trackID)
            }
        }
        requiredSourceTrackIDs = Array(trackIDSet)
            .filter { $0 != kCMPersistentTrackID_Invalid }
            .compactMap { $0 as NSValue }
    }
}
