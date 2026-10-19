//
//  VideoCompositor.swift
//  VideoLab
//
//  Created by Bear on 02/19/2020.
//  Copyright (c) 2020 Chocolate. All rights reserved.
//

import AVFoundation

class VideoCompositor: NSObject, AVVideoCompositing {
    private var renderingQueue = DispatchQueue(label: "com.studio.VideoLab.renderingqueue")
    private var renderContextQueue = DispatchQueue(label: "com.studio.VideoLab.rendercontextqueue")
    private var renderContext: AVVideoCompositionRenderContext?
    private var shouldCancelAllRequests = false
    
    private let layerCompositor = LayerCompositor()
    
    // Accept original source colors and convert to SDR inside LayerCompositor.
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }
    var canConformColorOfSourceFrames: Bool { true }

    // MARK: - AVVideoCompositing
    var sourcePixelBufferAttributes: [String : Any]? =
        [String(kCVPixelBufferPixelFormatTypeKey): [Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                                                    Int(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
                                                    Int(kCVPixelFormatType_32BGRA),
                                                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)],
         String(kCVPixelBufferMetalCompatibilityKey): true]
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] =
        [String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_32BGRA),
         String(kCVPixelBufferOpenGLESCompatibilityKey): true]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderingQueue.sync {
            renderContext = newRenderContext
        }
    }
    
    enum PixelBufferRequestError: Error {
        case newRenderedPixelBufferForRequestFailure
    }
    
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            renderingQueue.async {
                if self.shouldCancelAllRequests {
                    request.finishCancelledRequest()
                } else {
                    guard let resultPixels = self.newRenderedPixelBufferForRequest(request) else {
                        request.finish(with: PixelBufferRequestError.newRenderedPixelBufferForRequestFailure)
                        return
                    }
                    
                    request.finish(withComposedVideoFrame: resultPixels)
                }
            }
        }
    }
    
    func cancelAllPendingVideoCompositionRequests() {
        renderingQueue.sync {
            shouldCancelAllRequests = true
        }
        renderingQueue.async {
            self.shouldCancelAllRequests = false
        }
    }
    
    // MARK: - Private
    func newRenderedPixelBufferForRequest(_ request: AVAsynchronousVideoCompositionRequest) -> CVPixelBuffer? {
        guard let newPixelBuffer = renderContext?.newPixelBuffer() else {
            return nil
        }
        
        let rendered = layerCompositor.renderPixelBuffer(newPixelBuffer, for: request)
        // Drain converted buffers even when rendering fails partway through.
        let conversionFinished = layerCompositor.finishSourceConversion()
        let renderingFinished = LayerCompositor.waitForRenderingCommands()
        guard rendered, conversionFinished, renderingFinished else { return nil }
        
        return newPixelBuffer
    }
}

/// Opt-in HDR compositor. Uses an independent instance/queue so SDR preview and
/// HDR export never change a process-wide pixel format or shared color policy.
public final class HDRVideoCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "com.studio.VideoLab.hdr-rendering")
    private let renderer = LayerCompositor(hdr: true)
    private let cancellationLock = NSLock()
    private var generation: UInt = 0

    public var supportsHDRSourceFrames: Bool { true }
    public var supportsWideColorSourceFrames: Bool { true }
    public var canConformColorOfSourceFrames: Bool { true }
    public var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        cancellationLock.lock()
        let submittedGeneration = generation
        cancellationLock.unlock()
        queue.async {
            autoreleasepool {
                guard !self.isCancelled(submittedGeneration) else {
                    request.finishCancelledRequest()
                    return
                }
                guard let buffer = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "VideoLab.HDR", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot allocate an HDR output frame."]))
                    return
                }
                let rendered = self.renderer.renderPixelBuffer(buffer, for: request)
                let conversionFinished = self.renderer.finishSourceConversion()
                let renderingFinished = LayerCompositor.waitForRenderingCommands()
                guard rendered, conversionFinished, renderingFinished else {
                    request.finish(with: NSError(domain: "VideoLab.HDR", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "HDR frame rendering failed."]))
                    return
                }
                if self.isCancelled(submittedGeneration) { request.finishCancelledRequest() }
                else { request.finish(withComposedVideoFrame: buffer) }
            }
        }
    }

    private func isCancelled(_ submittedGeneration: UInt) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return generation != submittedGeneration
    }

    public func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock()
        generation &+= 1
        cancellationLock.unlock()
    }
}
