//
//  LayerCompositor.swift
//  VideoLab
//
//  Created by Bear on 2020/8/15.
//  Copyright (c) 2020 Chocolate. All rights reserved.
//

import AVFoundation
import CoreImage
import Metal

class LayerCompositor {
    private let hdr: Bool
    private var renderFailed = false
    private var workingPixelFormat: MTLPixelFormat { hdr ? .rgba16Float : .bgra8Unorm }
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private let hlgColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    private let overlayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var colorContext = CIContext(mtlCommandQueue: sharedMetalRenderingDevice.commandQueue,
        options: [.workingColorSpace: linearColorSpace,
                  .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false])
    // Caller-provided linear gain and optional white signal. Exposure policy
    // and the choice of reference white belong to the app, not the renderer.
    private var graphicsGainMultiplier: Float = 1
    private var graphicsReferenceWhiteHLG: Float?
    private var graphicsWhiteInWorkingSpace: CGFloat?
    private var graphicsGains: [(colorSpace: CGColorSpace, gain: CGFloat)] = []
#if DEBUG
    private var loggedGraphicsSources = Set<ObjectIdentifier>()
#endif

    private let sdrColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private lazy var sdrContext = CIContext(mtlCommandQueue: sharedMetalRenderingDevice.commandQueue,
        options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                  .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false])
    private var sdrPool: CVPixelBufferPool?
    private var sdrPoolWidth = 0
    private var sdrPoolHeight = 0
    // Retain converted SDR buffers and original HDR buffers through GPU use.
    private var convertedBuffers: [CVPixelBuffer] = []

    init(hdr: Bool = false) { self.hdr = hdr }
    let passthrough = Passthrough()
    let rotatePassThrough = RotatePassthrough()
    let yuvToRGBConversion = YUVToRGBConversion()
    let blendOperation = BlendOperation()

    // MARK: - Public
    func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, for request: AVAsynchronousVideoCompositionRequest) -> Bool {
        renderFailed = false
        if hdr {
            guard let instruction = request.videoCompositionInstruction as? VideoCompositionInstruction else { return false }
            if graphicsGainMultiplier != instruction.hdrGraphicsGain ||
                graphicsReferenceWhiteHLG != instruction.hdrGraphicsReferenceWhiteHLG {
                if graphicsReferenceWhiteHLG != instruction.hdrGraphicsReferenceWhiteHLG {
                    // Resolve white through the actual output color transform;
                    // do not assume a fixed luminance for linear 1.0.
                    graphicsWhiteInWorkingSpace = instruction.hdrGraphicsReferenceWhiteHLG.flatMap {
                        workingWhiteLevel(signal: CGFloat($0), in: hlgColorSpace)
                    }
                }
                graphicsGainMultiplier = instruction.hdrGraphicsGain
                graphicsReferenceWhiteHLG = instruction.hdrGraphicsReferenceWhiteHLG
                graphicsGains.removeAll()
#if DEBUG
                loggedGraphicsSources.removeAll()
#endif
            }
            return renderHDRPixelBuffer(pixelBuffer, for: request)
        }
        guard let instruction = request.videoCompositionInstruction as? VideoCompositionInstruction else {
            return false
        }
        guard let outputTexture = Texture.makeTexture(pixelBuffer: pixelBuffer) else {
            return false
        }
        Texture.clearTexture(outputTexture)
        guard instruction.videoRenderLayers.count > 0 else {
            return true
        }

        for (index, videoRenderLayer) in instruction.videoRenderLayers.enumerated() {
            autoreleasepool {
                // The first output must be disabled for reading, because newPixelBuffer is taken from the buffer pool, it may be the previous pixelBuffer
                let enableOutputTextureRead = (index != 0)
                renderLayer(videoRenderLayer, outputTexture: outputTexture, enableOutputTextureRead: enableOutputTextureRead, for: request)
            }
        }
        return !renderFailed
    }

    private func renderHDRPixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                     for request: AVAsynchronousVideoCompositionRequest) -> Bool {
        guard let instruction = request.videoCompositionInstruction as? VideoCompositionInstruction,
              let texture = sharedMetalRenderingDevice.textureCache.requestTexture(pixelFormat: .rgba16Float,
                  width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) else { return false }
        texture.lock()
        defer { texture.unlock() }
        Texture.clearTexture(texture)
        for (index, layer) in instruction.videoRenderLayers.enumerated() {
            autoreleasepool {
                renderLayer(layer, outputTexture: texture, enableOutputTextureRead: index != 0, for: request)
            }
        }
        let commandsCompleted = Self.waitForRenderingCommands()
        guard commandsCompleted, !renderFailed,
              let image = imageFromTopLeftTexture(texture.texture, colorSpace: linearColorSpace) else { return false }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        colorContext.render(image, to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: texture.width, height: texture.height), colorSpace: hlgColorSpace)
        // Keep the working texture out of the shared cache until CI finishes.
        return Self.waitForRenderingCommands()
    }

    static func waitForRenderingCommands() -> Bool {
        guard let fence = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer() else { return false }
        fence.commit()
        fence.waitUntilCompleted()
        return fence.status == .completed
    }

    // VideoLab samples Metal textures with (0, 0) at the top left. Core Image
    // interprets a Metal texture's first row as the bottom of its image.
    // Convert at the boundary, before applying any layer/track transforms.
    private func imageFromTopLeftTexture(_ texture: MTLTexture, colorSpace: CGColorSpace) -> CIImage? {
        CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])?.transformed(
            by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(texture.height)))
    }

    private func renderTopLeftTexture(_ image: CIImage, to texture: MTLTexture) -> Bool {
        guard let command = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer() else { return false }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        // Store Core Image's upper row in Metal row zero, matching VideoLab's
        // existing CVMetalTexture-backed SDR path and texture coordinates.
        destination.isFlipped = true
        destination.colorSpace = linearColorSpace
        destination.alphaMode = .premultiplied
        destination.isClamped = false
        do {
            _ = try colorContext.startTask(toRender: image,
                from: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
                to: destination, at: .zero)
            command.commit()
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Private
    private func renderLayer(_ videoRenderLayer: VideoRenderLayer,
                     outputTexture: Texture?,
                     enableOutputTextureRead: Bool,
                     for request: AVAsynchronousVideoCompositionRequest) {
        guard let outputTexture = outputTexture else {
            renderFailed = true
            return
        }

        // Convert composite time to internal layer time
        let layerInternalTime = request.compositionTime - videoRenderLayer.timeRangeInTimeline.start

        videoRenderLayer.renderLayer.syncTimes(compositionTime: request.compositionTime, instructionTimeRange: request.videoCompositionInstruction.timeRange)

        // Update keyframe animation values
        videoRenderLayer.renderLayer.updateAnimationValues(at: layerInternalTime)
        
        // Texture layer: layer source contains video track, layer source is image, layer group
        // The steps to render the texture layer
        // Step 1: Handle its own operations
        // Step 2: Blend with the previous output texture. The previous output texture is a read back renderbuffer
        func renderTextureLayer(_ sourceTexture: Texture) {
            for operation in videoRenderLayer.renderLayer.operations {
                autoreleasepool {
                    if operation.shouldInputSourceTexture {
                        guard let clonedSourceTexture = cloneTexture(from: sourceTexture) else {
                            renderFailed = true
                            return
                        }
                        operation.addTexture(clonedSourceTexture, at: 0)
                        operation.renderTexture(sourceTexture)
                        clonedSourceTexture.unlock()
                    } else {
                        operation.renderTexture(sourceTexture)
                    }
                }
            }
            
            blendOutputText(outputTexture,
                            with: sourceTexture,
                            blendMode: videoRenderLayer.renderLayer.blendMode,
                            blendOpacity: videoRenderLayer.renderLayer.blendOpacity,
                            transform: videoRenderLayer.renderLayer.transform,
                            enableOutputTextureRead: enableOutputTextureRead)
        }
        
        if let videoRenderLayerGroup = videoRenderLayer as? VideoRenderLayerGroup {
            // Layer group
            let textureWidth = outputTexture.width
            let textureHeight = outputTexture.height
            guard let groupTexture = sharedMetalRenderingDevice.textureCache.requestTexture(pixelFormat: workingPixelFormat, width: textureWidth, height: textureHeight) else {
                renderFailed = true
                return
            }
            groupTexture.lock()
            Texture.clearTexture(groupTexture)

            // Preserve VideoLab's end-inclusive sampling for the final frame.
            // containsTime excludes the endpoint and can leave a cleared group
            // with no child layers when the request lands exactly on its end.
            let intersectingVideoRenderLayers = videoRenderLayerGroup.videoRenderLayers.filter {
                $0.timeRangeInTimeline.start <= request.compositionTime
                    && request.compositionTime <= $0.timeRangeInTimeline.end
            }
            for (index, subVideoRenderLayer) in intersectingVideoRenderLayers.enumerated() {
                autoreleasepool {
                    // The first output must be disabled for reading, because groupTexture is taken from the texture cache, it may be the previous texture
                    let enableOutputTextureRead = (index != 0)
                    renderLayer(subVideoRenderLayer, outputTexture: groupTexture, enableOutputTextureRead: enableOutputTextureRead, for: request)
                }
            }
            
            renderTextureLayer(groupTexture)
            groupTexture.unlock()
        } else if videoRenderLayer.trackID != kCMPersistentTrackID_Invalid {
            // Texture layer source contains a video track
            guard let pixelBuffer = request.sourceFrame(byTrackID: videoRenderLayer.trackID) else {
                renderFailed = true
                return
            }
            
            guard let videoTexture = bgraVideoTexture(from: pixelBuffer,
                                                      preferredTransform: videoRenderLayer.preferredTransform,
                                                      presentationSize: videoRenderLayer.presentationSize) else {
                renderFailed = true
                return
            }
            
            renderTextureLayer(videoTexture)
            if videoTexture.textureRetainCount > 0 {
                // Lock is invoked in the bgraVideoTexture method
                videoTexture.unlock()
            }
        } else if let source = videoRenderLayer.renderLayer.source,
                  let sourceTexture = source.texture(at: layerInternalTime) {
            // Texture layer source is a image
            let graphicsColorSpace = source.hdrGraphicsColorSpace
            guard let imageTexture = cloneTexture(from: sourceTexture, isSDROverlay: true,
                                                 graphicsColorSpace: graphicsColorSpace) else {
                renderFailed = true
                return
            }
#if DEBUG
            if hdr, let graphicsColorSpace {
                logGraphicsPixels(source: source, input: sourceTexture, mapped: imageTexture,
                    colorSpace: graphicsColorSpace, time: request.compositionTime,
                    blendOpacity: videoRenderLayer.renderLayer.blendOpacity)
            }
#endif
            
            renderTextureLayer(imageTexture)
            // Lock is invoked in the imageTexture method
            imageTexture.unlock()
        } else {
            // Layer without texture. All operations of the layer are applied to the previous output texture
            for operation in videoRenderLayer.renderLayer.operations {
                autoreleasepool {
                    if operation.shouldInputSourceTexture, let clonedOutputTexture = cloneTexture(from: outputTexture) {
                        operation.addTexture(clonedOutputTexture, at: 0)
                        operation.renderTexture(outputTexture)
                        clonedOutputTexture.unlock()
                    } else {
                        operation.renderTexture(outputTexture)
                    }
                }
            }
        }
    }

    private func bgraVideoTexture(from sourcePixelBuffer: CVPixelBuffer, preferredTransform: CGAffineTransform, presentationSize: CGSize?) -> Texture? {
        if hdr { return hdrVideoTexture(from: sourcePixelBuffer, preferredTransform: preferredTransform, presentationSize: presentationSize) }
        guard let pixelBuffer = sdrSourceBuffer(sourcePixelBuffer) else {
            renderFailed = true
            return nil
        }
        var videoTexture: Texture?
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let videoTextureSize = self.videoTextureSize(bufferWidth: bufferWidth,
                                                     bufferHeight: bufferHeight,
                                                     preferredTransform: preferredTransform,
                                                     presentationSize: presentationSize)

        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer);
        if pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            let luminanceTexture = Texture.makeTexture(pixelBuffer: pixelBuffer, pixelFormat: .r8Unorm, width:bufferWidth, height: bufferHeight, plane: 0)
            let chrominanceTexture = Texture.makeTexture(pixelBuffer: pixelBuffer, pixelFormat: .rg8Unorm, width: bufferWidth / 2, height: bufferHeight / 2, plane: 1)
            if let luminanceTexture = luminanceTexture, let chrominanceTexture = chrominanceTexture {
                videoTexture = sharedMetalRenderingDevice.textureCache.requestTexture(width: videoTextureSize.width, height: videoTextureSize.height)
                if let videoTexture = videoTexture {
                    videoTexture.lock()
                    
                    let colorConversionMatrix = pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? YUVToRGBConversion.colorConversionMatrixVideoRange : YUVToRGBConversion.colorConversionMatrixFullRange
                    yuvToRGBConversion.colorConversionMatrix = colorConversionMatrix
                    let orientationMatrix = preferredTransform.normalizeOrientationMatrix()
                    yuvToRGBConversion.orientation = orientationMatrix
                    yuvToRGBConversion.addTexture(luminanceTexture, at: 0)
                    yuvToRGBConversion.addTexture(chrominanceTexture, at: 1)
                    yuvToRGBConversion.renderTexture(videoTexture)
                }
            }
        }
        else if pixelFormatType == kCVPixelFormatType_32BGRA {
            let fullDataTexture = Texture.makeTexture(pixelBuffer: pixelBuffer, pixelFormat: .bgra8Unorm, width:bufferWidth, height: bufferHeight, plane: 0)
            if let fullDataTexture {
                videoTexture = sharedMetalRenderingDevice.textureCache.requestTexture(width: videoTextureSize.width, height: videoTextureSize.height)
                if let videoTexture = videoTexture {
                    videoTexture.lock()
                    let orientationMatrix = preferredTransform.normalizeOrientationMatrix()
                    rotatePassThrough.orientation = orientationMatrix
                    rotatePassThrough.addTexture(fullDataTexture, at: 0)
                    rotatePassThrough.renderTexture(videoTexture)
                }
            }
        }
        else {
            videoTexture = Texture.makeTexture(pixelBuffer: pixelBuffer)
        }
        return videoTexture
    }

    private func sdrSourceBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        func tag(_ key: CFString) -> String? {
            CVBufferGetAttachment(source, key, nil)?.takeUnretainedValue() as? String
        }
        let transfer = tag(kCVImageBufferTransferFunctionKey)
        let primaries = tag(kCVImageBufferColorPrimariesKey)
        let matrix = tag(kCVImageBufferYCbCrMatrixKey)
        let format = CVPixelBufferGetPixelFormatType(source)
        let hdr = transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let otherColor = (primaries != nil && primaries != (kCVImageBufferColorPrimaries_ITU_R_709_2 as String))
            || (transfer != nil && transfer != (kCVImageBufferTransferFunction_ITU_R_709_2 as String))
            || (matrix != nil && matrix != (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
        guard hdr || tenBit || otherColor else { return source }

        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if sdrPool == nil || width != sdrPoolWidth || height != sdrPoolHeight {
            sdrPool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &sdrPool) == kCVReturnSuccess else { return nil }
            sdrPoolWidth = width
            sdrPoolHeight = height
        }
        guard let pool = sdrPool else { return nil }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess,
              let result = result else { return nil }
        // CVPixelBuffer -> CVPixelBuffer keeps the existing video orientation.
        // Track rotation is still applied exactly once by the old Metal path.
        let image = CIImage(cvPixelBuffer: source, options: [.toneMapHDRtoSDR: hdr])
        sdrContext.render(image, to: result,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: sdrColorSpace)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        convertedBuffers.append(result)
        return result
    }

    // Converted pool buffers must remain alive until Metal finishes sampling them.
    func finishSourceConversion() -> Bool {
        guard !convertedBuffers.isEmpty else { return !renderFailed }
        guard let completion = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer() else { return false }
        completion.commit()
        completion.waitUntilCompleted()
        convertedBuffers.removeAll()
        return completion.status == .completed && !renderFailed
    }

    private func videoTextureSize(bufferWidth: Int, bufferHeight: Int, preferredTransform: CGAffineTransform, presentationSize: CGSize?) -> (width: Int, height: Int) {
        if let presentationSize = presentationSize,
           let width = textureDimension(presentationSize.width),
           let height = textureDimension(presentationSize.height) {
            return (width, height)
        }

        let transformedSize = CGSize(width: bufferWidth, height: bufferHeight).applying(preferredTransform)
        let width = textureDimension(transformedSize.width) ?? max(bufferWidth, 1)
        let height = textureDimension(transformedSize.height) ?? max(bufferHeight, 1)
        return (width, height)
    }

    private func textureDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite else {
            return nil
        }

        let dimension = abs(value).rounded()
        guard dimension > 0 else {
            return nil
        }

        return Int(dimension)
    }
    
    private func cloneTexture(from sourceTexture: Texture, isSDROverlay: Bool = false,
                              graphicsColorSpace: CGColorSpace? = nil) -> Texture? {
        let textureWidth = sourceTexture.width
        let textureHeight = sourceTexture.height
    
        guard let cloneTexture = sharedMetalRenderingDevice.textureCache.requestTexture(pixelFormat: workingPixelFormat, width: textureWidth, height: textureHeight) else {
            return nil
        }
        cloneTexture.lock()
        if hdr, isSDROverlay {
            guard var image = imageFromTopLeftTexture(sourceTexture.texture,
                colorSpace: graphicsColorSpace ?? overlayColorSpace) else {
                cloneTexture.unlock()
                return nil
            }
            if let graphicsColorSpace {
                guard let gain = graphicsGain(for: graphicsColorSpace) else {
                    cloneTexture.unlock()
                    return nil
                }
                image = applyingGraphicsGain(gain, to: image)
            }
            guard renderTopLeftTexture(image, to: cloneTexture.texture) else {
                cloneTexture.unlock()
                return nil
            }
            return cloneTexture
        }
        
        passthrough.addTexture(sourceTexture, at: 0)
        passthrough.renderTexture(cloneTexture)
        return cloneTexture
    }

    private func applyingGraphicsGain(_ gain: CGFloat, to image: CIImage) -> CIImage {
        // CIColorMatrix operates on unpremultiplied values in colorContext's
        // linear BT.2020 working space. Core Image handles un/premultiplication;
        // the alpha row stays identity and no offset or RGB clamp is introduced.
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private func graphicsGain(for colorSpace: CGColorSpace) -> CGFloat? {
        if let cached = graphicsGains.first(where: { CFEqual($0.colorSpace, colorSpace) }) {
            return cached.gain
        }
        let referenceGain: CGFloat
        if graphicsReferenceWhiteHLG != nil {
            guard let targetWhite = graphicsWhiteInWorkingSpace,
                  let sourceWhite = workingWhiteLevel(signal: 1, in: colorSpace) else { return nil }
            referenceGain = targetWhite / sourceWhite
        } else {
            referenceGain = 1
        }
        let gain = referenceGain * CGFloat(graphicsGainMultiplier)
        guard gain.isFinite, gain >= 0 else { return nil }
        graphicsGains.append((colorSpace, gain))
#if DEBUG
        print("[VideoColor] graphicsWhite source=\(String(describing: colorSpace.name)), referenceLinear=\(String(describing: graphicsWhiteInWorkingSpace)), referenceGain=\(referenceGain), referenceHLG=\(String(describing: graphicsReferenceWhiteHLG)), graphicsGain=\(graphicsGainMultiplier), appliedGain=\(gain)")
#endif
        return gain
    }

    private func workingWhiteLevel(signal: CGFloat, in colorSpace: CGColorSpace) -> CGFloat? {
        guard let color = CIColor(red: signal, green: signal, blue: signal, alpha: 1,
                                  colorSpace: colorSpace) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let image = CIImage(color: color).cropped(to: bounds)
        var rgba = [Float](repeating: .nan, count: 4)
        // A one-pixel conversion per source color space, cached until rendering
        // parameters change. No frame readback or display-headroom dependency.
        rgba.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            colorContext.render(image, toBitmap: baseAddress, rowBytes: 4 * MemoryLayout<Float>.stride,
                                bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        guard rgba.allSatisfy({ $0.isFinite }), rgba[3] > 0,
              rgba[0] > 0, rgba[1] > 0, rgba[2] > 0 else { return nil }
        return CGFloat((rgba[0] + rgba[1] + rgba[2]) / 3)
    }

#if DEBUG
    private func logGraphicsPixels(source: Source, input: Texture, mapped: Texture,
                                   colorSpace: CGColorSpace, time: CMTime, blendOpacity: Float) {
        let sourceID = ObjectIdentifier(source as AnyObject)
        guard loggedGraphicsSources.insert(sourceID).inserted else { return }
        let label = "compositor=\(ObjectIdentifier(self)), source=\(type(of: source))@\(sourceID), pts=\(time.seconds)"
        guard Self.waitForRenderingCommands(),
              let inputImage = imageFromTopLeftTexture(input.texture, colorSpace: colorSpace),
              let mappedImage = imageFromTopLeftTexture(mapped.texture, colorSpace: linearColorSpace),
              let inputPixels = graphicsPixelSample(inputImage),
              let mappedPixels = graphicsPixelSample(mappedImage),
              let gain = graphicsGains.first(where: { CFEqual($0.colorSpace, colorSpace) })?.gain else {
            print("[VideoColor] graphicsPixels \(label), sampleUnavailable=true")
            return
        }

        var visible = 0, opaque = 0
        var inputMean: Float = 0, mappedMean: Float = 0
        var inputPeak: Float = 0, mappedPeak: Float = 0
        var maxAlphaDifference: Float = 0, maxGainDifference: Float = 0
        for offset in stride(from: 0, to: inputPixels.count, by: 4) {
            let alpha = inputPixels[offset + 3]
            let mappedAlpha = mappedPixels[offset + 3]
            maxAlphaDifference = max(maxAlphaDifference, abs(mappedAlpha - alpha))
            // Tiny-alpha edge samples are unsuitable for unpremultiplied stats.
            guard alpha > 0.01, mappedAlpha > 0.01 else { continue }
            visible += 1
            if alpha >= 0.99 { opaque += 1 }
            let inputRGB = SIMD3<Float>(inputPixels[offset], inputPixels[offset + 1], inputPixels[offset + 2]) / alpha
            let mappedRGB = SIMD3<Float>(mappedPixels[offset], mappedPixels[offset + 1], mappedPixels[offset + 2]) / mappedAlpha
            inputMean += 0.2627 * inputRGB.x + 0.6780 * inputRGB.y + 0.0593 * inputRGB.z
            mappedMean += 0.2627 * mappedRGB.x + 0.6780 * mappedRGB.y + 0.0593 * mappedRGB.z
            inputPeak = max(inputPeak, max(inputRGB.x, max(inputRGB.y, inputRGB.z)))
            mappedPeak = max(mappedPeak, max(mappedRGB.x, max(mappedRGB.y, mappedRGB.z)))
            let delta = mappedRGB - inputRGB * Float(gain)
            maxGainDifference = max(maxGainDifference, max(abs(delta.x), max(abs(delta.y), abs(delta.z))))
        }
        if visible > 0 {
            inputMean /= Float(visible)
            mappedMean /= Float(visible)
        }
        let observedGain = inputMean > 0 ? String(mappedMean / inputMean) : "unavailable"
        print("[VideoColor] graphicsPixels \(label), space=linearBT2020, grid=32x32, visible=\(visible), opaque=\(opaque), blendOpacity=\(blendOpacity), inputMean=\(inputMean), mappedMean=\(mappedMean), inputPeak=\(inputPeak), mappedPeak=\(mappedPeak), expectedGain=\(gain), observedGain=\(observedGain), maxAlphaDifference=\(maxAlphaDifference), maxGainDifference=\(maxGainDifference)")
    }

    private func graphicsPixelSample(_ image: CIImage) -> [Float]? {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        let reduced = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: bounds.width / extent.width, y: bounds.height / extent.height))
        var pixels = [Float](repeating: .nan, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            colorContext.render(reduced, toBitmap: baseAddress, rowBytes: 32 * 4 * MemoryLayout<Float>.stride,
                                bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels.allSatisfy({ $0.isFinite }) ? pixels : nil
    }
#endif

    private func hdrVideoTexture(from buffer: CVPixelBuffer, preferredTransform: CGAffineTransform,
                                 presentationSize: CGSize?) -> Texture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let size = videoTextureSize(bufferWidth: width, bufferHeight: height,
                                   preferredTransform: preferredTransform, presentationSize: presentationSize)
        guard let linear = sharedMetalRenderingDevice.textureCache.requestTexture(pixelFormat: .rgba16Float, width: width, height: height) else { return nil }
        linear.lock()
        defer { linear.unlock() }
        // Core Image reads the original HLG/PQ/SDR buffer attachments and converts
        // into extended linear BT.2020; values above SDR white remain unclipped.
        convertedBuffers.append(buffer)
        guard renderTopLeftTexture(CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: false]),
                                   to: linear.texture) else { return nil }
        guard let result = sharedMetalRenderingDevice.textureCache.requestTexture(pixelFormat: .rgba16Float,
            width: size.width, height: size.height) else { return nil }
        result.lock()
        rotatePassThrough.orientation = preferredTransform.normalizeOrientationMatrix()
        rotatePassThrough.addTexture(linear, at: 0)
        rotatePassThrough.renderTexture(result)
        return result
    }
    
    private func blendOutputText(_ outputTexture: Texture,
                                 with texture: Texture,
                                 blendMode: BlendMode,
                                 blendOpacity: Float,
                                 transform: Transform,
                                 enableOutputTextureRead: Bool) {
        // Generate model, view, projection matrix
        let renderSize = CGSize(width: outputTexture.width, height: outputTexture.height)
        let textureSize = CGSize(width: texture.width, height: texture.height)
        let modelViewMatrix = transform.modelViewMatrix(textureSize: textureSize, renderSize: renderSize)
        let projectionMatrix = transform.projectionMatrix(renderSize: renderSize)
        
        // Update blend parameters
        blendOperation.modelView = modelViewMatrix
        blendOperation.projection = projectionMatrix
        blendOperation.blendMode = blendMode
        blendOperation.blendOpacity = blendOpacity
        
        // Render
        blendOperation.enableOutputTextureRead = enableOutputTextureRead
        blendOperation.addTexture(texture, at: 0)
        blendOperation.renderTexture(outputTexture)
    }
}
