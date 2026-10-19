//
//  BasicOperation.swift
//  VideoLab
//
//  Created by Bear on 2020/8/21.
//  Copyright © 2020 Chocolate. All rights reserved.
//

import CoreMedia
import Metal

public func defaultVertexFunctionNameForInputs(_ inputCount:UInt) -> String {
    switch inputCount {
    case 0:
        return "passthroughVertex"
    case 1:
        return "oneInputVertex"
    case 2:
        return "twoInputVertex"
    default:
        return "passthroughVertex"
    }
}

open class BasicOperation: Animatable {
    public let maximumInputs: UInt
    public var uniformSettings: ShaderUniformSettings
    public var enableOutputTextureRead = true
    public var shouldInputSourceTexture = false
    public var timeRange: CMTimeRange?
    public let renderPipelineState: MTLRenderPipelineState
    private let pipelineVertexName: String
    private let pipelineFragmentName: String
    private var formatPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    let operationName: String
    public var inputTextures = [UInt: Texture]()
    public var textureClearColor: Color? = .transparent
    public let textureInputSemaphore = DispatchSemaphore(value:1)
    
    public init(vertexFunctionName: String? = nil, fragmentFunctionName: String, numberOfInputs: UInt = 1, operationName: String = #file) {
        self.maximumInputs = numberOfInputs
        self.operationName = operationName
        
        let concreteVertexFunctionName = vertexFunctionName ?? defaultVertexFunctionNameForInputs(numberOfInputs)
        pipelineVertexName = concreteVertexFunctionName
        pipelineFragmentName = fragmentFunctionName
        
        let (pipelineState, vertexUniforms, fragmentUniforms) = generateRenderPipelineState(vertexFunctionName:concreteVertexFunctionName,
                                                                       fragmentFunctionName:fragmentFunctionName,
                                                                       operationName:operationName)
        self.renderPipelineState = pipelineState
        self.uniformSettings = ShaderUniformSettings(vertexUniforms: vertexUniforms, fragmentUniforms: fragmentUniforms)
    }
    
    open func addTexture(_ texture: Texture, at index: UInt) {
        inputTextures[index] = texture
    }
    
    open func renderTexture(_ outputTexture: Texture) {
        let _ = textureInputSemaphore.wait(timeout:DispatchTime.distantFuture)
        defer {
            textureInputSemaphore.signal()
        }
        
        if inputTextures.count >= maximumInputs {
            guard let commandBuffer = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer() else {
                return
            }
            
            commandBuffer.renderQuad(pipelineState: pipelineState(for: outputTexture),
                                     uniformSettings: uniformSettings,
                                     inputTextures: inputTextures,
                                     outputTexture: outputTexture,
                                     textureClearColor: textureClearColor,
                                     enableOutputTextureRead: enableOutputTextureRead)
            commandBuffer.commit()
        }
    }

    /// Call under textureInputSemaphore, as renderTexture and custom operations do.
    public func pipelineState(for outputTexture: Texture) -> MTLRenderPipelineState {
        let format = outputTexture.texture.pixelFormat
        if format == .bgra8Unorm { return renderPipelineState }
        if let state = formatPipelines[format] { return state }
        let (state, _, _) = generateRenderPipelineState(vertexFunctionName: pipelineVertexName,
            fragmentFunctionName: pipelineFragmentName, operationName: operationName, pixelFormat: format)
        formatPipelines[format] = state
        return state
    }
    
    // MARK: - Animatable
    public var animations: [KeyframeAnimation]?
    open func updateAnimationValues(at time: CMTime) {}
}
