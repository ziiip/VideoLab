#include <metal_stdlib>
#include "OperationShaderTypes.h"

using namespace metal;

vertex PassthroughVertexIO passthroughVertex(const device packed_float2 *position [[buffer(0)]],
                                             uint vid [[vertex_id]])
{
    PassthroughVertexIO outputVertices;
    
    outputVertices.position = float4(position[vid], 0, 1.0);

    return outputVertices;
}

vertex SingleInputVertexIO oneInputVertex(const device packed_float2 *position [[buffer(0)]],
                                          const device packed_float2 *texturecoord [[buffer(1)]],
                                          uint vid [[vertex_id]])
{
    SingleInputVertexIO outputVertices;
    
    outputVertices.position = float4(position[vid], 0, 1.0);
    outputVertices.textureCoordinate = texturecoord[vid];
    
    return outputVertices;
}

fragment half4 oneInputPassthroughFragment(SingleInputVertexIO fragmentInput [[stage_in]],
                                           texture2d<half> inputTexture [[texture(0)]])
{
    constexpr sampler quadSampler;
    half4 color = inputTexture.sample(quadSampler, fragmentInput.textureCoordinate);
    
    return color;
}

vertex TwoInputVertexIO twoInputVertex(const device packed_float2 *position [[buffer(0)]],
                                       const device packed_float2 *texturecoord [[buffer(1)]],
                                       const device packed_float2 *texturecoord2 [[buffer(2)]],
                                       uint vid [[vertex_id]])
{
    TwoInputVertexIO outputVertices;
    
    outputVertices.position = float4(position[vid], 0, 1.0);
    outputVertices.textureCoordinate = texturecoord[vid];
    outputVertices.textureCoordinate2 = texturecoord2[vid];

    return outputVertices;
}



// =====
vertex SingleInputVertexIO rotatePassthroughVertex(const device packed_float2 *position [[buffer(0)]],
                                            const device packed_float2 *texturecoord [[buffer(1)]],
                                            constant float4x4& orientation [[ buffer(3) ]],
                                            uint vid [[vertex_id]])
{
    SingleInputVertexIO outputVertices;

    outputVertices.position = float4(position[vid], 0, 1.0);
    outputVertices.textureCoordinate = (orientation * float4(texturecoord[vid], 0, 1.0)).xy;

    return outputVertices;
}

fragment half4 rotatePassthroughFragment(SingleInputVertexIO fragmentInput [[stage_in]],
                                     texture2d<half> inputTexture [[texture(0)]],
                                     constant float4x4& colorConversionMatrix [[ buffer(1) ]])
{
    constexpr sampler quadSampler;
    half4 color = inputTexture.sample(quadSampler, fragmentInput.textureCoordinate).rgba;
    return clamp(color, 0.0, 1.0);
}
