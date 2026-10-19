//
//  Source.swift
//  VideoLab
//
//  Created by Bear on 2020/8/29.
//  Copyright © 2020 Chocolate. All rights reserved.
//

import AVFoundation
import CoreGraphics

public protocol Source {
    var selectedTimeRange: CMTimeRange { get set }
    var duration: CMTime { get set }
    var isLoaded: Bool { get set }

    var weakContainerLayer: RenderLayer? { get set }

    /// Declared color space of a premultiplied graphics texture that participates
    /// in HDR graphics mapping. Nil preserves the source's legacy texture handling.
    var hdrGraphicsColorSpace: CGColorSpace? { get }

    func load(completion: @escaping (NSError?) -> Void)
    func tracks(for type: AVMediaType) -> [AVAssetTrack]
    func texture(at time: CMTime) -> Texture?
    
    func copy() -> Source
    
    func canBeVideoSource() -> Bool

    func syncTimes(compositionTime: CMTime, instructionTimeRange: CMTimeRange)
}

extension Source {
    public var hdrGraphicsColorSpace: CGColorSpace? { nil }

    public weak var weakContainerLayer: RenderLayer? {
        get { nil }
        set { }
    }
    
    public func texture(at time: CMTime) -> Texture? {
        return nil
    }

    public func canBeVideoSource() -> Bool {
        return false
    }

    public func syncTimes(compositionTime: CMTime, instructionTimeRange: CMTimeRange) { }
}
